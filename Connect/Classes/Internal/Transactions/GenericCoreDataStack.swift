/**
 *   GenericCoreDataStack.swift
 *
 *   Copyright 2016 Tony Stone
 *
 *   Licensed under the Apache License, Version 2.0 (the "License");
 *   you may not use this file except in compliance with the License.
 *   You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 *   Unless required by applicable law or agreed to in writing, software
 *   distributed under the License is distributed on an "AS IS" BASIS,
 *   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *   See the License for the specific language governing permissions and
 *   limitations under the License.
 *
 *   Created by Tony Stone on 1/6/16.
 */
import Foundation
import CoreData
import TraceLog

/**
    The name of the default configuration in the model.  If you have not 
    created any configurations, this will be the only configuration avaialble.

    Use this name if you override the options passed.
*/
internal let defaultModelConfigurationName: String = "Default"

/**
    An option – when set to true – will check if the persistent store and the model are incompatible.
    If so, the underlying persistent store will be removed and replaced.
 */
internal let CCOverwriteIncompatibleStoreOption: String = "overwriteIncompatibleStoreOption"

/**
    Default options passed to attached and configure the persistent stores.
 */
internal let defaultStoreOptions: [NSObject : AnyObject] = [
    NSMigratePersistentStoresAutomaticallyOption    : true,
    NSInferMappingModelAutomaticallyOption          : true
]

/**
    PersistentStore configuration settings.
 */
internal typealias PersistentStoreConfiguration = (storeType: String, storeOptions: [NSObject : AnyObject]?, migrationManager: NSMigrationManager?)

/**
    Configuration options dictionary keyed by configuration name.  
    The name is the name you listed in your model.
 */
internal typealias ConfigurationOptionsType = [String : PersistentStoreConfiguration]

/**
    The detault configuration options used to configure the persistent store when no override is supplied.
 */
internal let defaultConfigurationOptions: ConfigurationOptionsType = [defaultModelConfigurationName : (storeType: NSSQLiteStoreType, storeOptions: defaultStoreOptions, migrationManager: nil)]

/**
    There are activities that the CoreDataStack will do asyncrhonously as a result of various events.  GenericCoreDataStack currently 
    logs those events, if you would like to handle them yourself, you can set an error block which will be called to allow you to take 
    an alternate action.
 */
internal typealias asynErrorHandlerBlock = (NSError) -> Void

/**
    A Core Data stack that can be customized with specific NSPersistentStoreCoordinator and a NSManagedObjectContext Context type.
 */
internal class GenericCoreDataStack<CoordinatorType: NSPersistentStoreCoordinator, ContextType: NSManagedObjectContext> {
    
    private let managedObjectModel: NSManagedObjectModel
    private let persistentStoreCoordinator: CoordinatorType
    private let tag: String
    private let mainContext: ContextType
    private let errorHandlerBlock: (error: NSError) -> Void
    
    /**
        Initializes the receiver with a managed object model.
     
        - parameters:
          - managedObjectModel: A managed object model.
          - configurationOptions: Optional configuration settings by persistent store config name (see ConfigurationOptionsType for structure)
          - storeNamePrefix: An optional String which is appended to the beginning of the persistent store's name.
          - logTag: An optional String that will be used as the tag for logging (default is GenericCoreDataStack).  This is typically used if you are embedding GenericCoreDataStack in something else and you want to to log as your class.
     */
    internal init(managedObjectModel model: NSManagedObjectModel, storeNamePrefix: String, configurationOptions options: ConfigurationOptionsType = defaultConfigurationOptions, asyncErrorBlock: ((error: NSError) -> Void)? = nil, logTag tag: String = String(GenericCoreDataStack.self)) throws {
        
        self.managedObjectModel = model
        self.tag = tag
        
        if let asyncErrorBlock = asyncErrorBlock {
            self.errorHandlerBlock = asyncErrorBlock
        } else {
            self.errorHandlerBlock = { (error: NSError) -> Void in
                logError { error.localizedDescription }
            }
        }
        
        // Create the coordinator
        persistentStoreCoordinator = CoordinatorType(managedObjectModel: managedObjectModel)
        
        // Now the main thread context
        mainContext = ContextType(concurrencyType: .MainQueueConcurrencyType)
        mainContext.persistentStoreCoordinator = self.persistentStoreCoordinator
        
        //
        // Figure out where to put things
        //
        // Note: We use the applications bundle not the classes or modules.
        //
        let cachesURL = try NSFileManager.defaultManager().URLForDirectory(.DocumentDirectory, inDomain: .UserDomainMask, appropriateForURL: nil, create: false)
        
        logInfo(tag) { "Store path: \(cachesURL.path ?? "Unknown")" }
        
        let configurations = managedObjectModel.configurations
        
        // There is only one so it's the default configuration
        if configurations.count == 1 {
            
            let storeURL = cachesURL.URLByAppendingPathComponent("\(storeNamePrefix).sqlite")
            
            if let (storeType, storeOptions, migrationManager) = options[defaultModelConfigurationName] {
                try self.addPersistentStore(storeType, configuration: nil, URL: storeURL, options: storeOptions, migrationManger: migrationManager)
                
            } else {
                try self.addPersistentStore(NSSQLiteStoreType, configuration: nil, URL: storeURL, options: nil, migrationManger: nil)
            }
        } else {
            for configuration in configurations {
                
                if configuration != defaultModelConfigurationName {
                    
                    let storeURL = cachesURL.URLByAppendingPathComponent("\(storeNamePrefix)\(configuration).sqlite")
                    
                    if let (storeType, storeOptions, migrationManager) = options[configuration] {
                        try self.addPersistentStore(storeType, configuration: configuration, URL: storeURL, options: storeOptions, migrationManger: migrationManager)
                        
                    } else {
                        try self.addPersistentStore(NSSQLiteStoreType, configuration: configuration, URL: storeURL, options: nil, migrationManger: nil)
                    }
                }
            }
        }
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(GenericCoreDataStack.handleContextDidSaveNotification(_:)), name: NSManagedObjectContextDidSaveNotification, object: nil)
    }
    
    deinit {
        NSNotificationCenter.defaultCenter().removeObserver(self)
    }

    internal func mainThreadContext () -> NSManagedObjectContext {
        return mainContext
    }

    internal func editContext () -> NSManagedObjectContext {
        
        logInfo(tag) { "Creating edit context for \(NSThread .currentThread())..." }
        
        let context = ContextType(concurrencyType: NSManagedObjectContextConcurrencyType.PrivateQueueConcurrencyType)
        context.parentContext = mainContext
        
        logInfo(tag) { "Edit context created." }
        
        return context
    }
    
    private func addPersistentStore(storeType: String, configuration: String?, URL storeURL: NSURL, options: [NSObject : AnyObject]?, migrationManger migrator: NSMigrationManager?) throws {
        
        do {
            //
            // If a migration manager was supplied, try a migration first.
            //
            if let migrationManager = migrator {
                
                if let mappingModel = NSMappingModel(fromBundles: nil, forSourceModel: migrationManager.sourceModel, destinationModel: migrationManager.destinationModel) {
                    
                    // TODO: Rename old file first
                    try migrationManager.migrateStoreFromURL(storeURL, type: storeType, options: options, withMappingModel: mappingModel, toDestinationURL: storeURL, destinationType: storeType, destinationOptions: options)
                }
            }
            
            logInfo(tag) { "Attaching persistent store \"\(storeURL.lastPathComponent ?? "Unknown")\" for type: \(persistentStoreType)."}

            let fileManager = NSFileManager.defaultManager()
            
            if let storePath = storeURL.path where fileManager.fileExistsAtPath(storePath) {
                
                let storeShmPath = "\(storePath)-shm"
                let storeWalPath = "\(storePath)-wal"
                
                // Check the store for compatibility if requested by developer.
                if options?[CCOverwriteIncompatibleStoreOption] as? Bool == true {
                    
                    logInfo(tag) { "Checking to see if persistent store is compatible with the model." }
                    
                    let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStoreOfType(storeType, URL: storeURL, options: nil)
                    logTrace(4) { "metadata: \(metadata)" }
                    
                    if !persistentStoreCoordinator.managedObjectModel.isConfiguration(configuration, compatibleWithStoreMetadata: metadata) {
                        
                        try deleteIfExists(storePath)
                        try deleteIfExists(storeShmPath)
                        try deleteIfExists(storeWalPath)
                    }
                }
            }
            
            logInfo(tag) { "Attaching new persistent store \"\(storeURL.lastPathComponent ?? "Unknown")\" for type: \(persistentStoreType)."}
            
            try persistentStoreCoordinator.addPersistentStoreWithType(storeType, configuration:  configuration, URL: storeURL, options: options)

            logInfo(tag) { "Persistent store attached successfully." }
            
        } catch let error as NSError where [NSMigrationError,
            NSMigrationConstraintViolationError,
            NSMigrationCancelledError,
            NSMigrationMissingSourceModelError,
            NSMigrationMissingMappingModelError,
            NSMigrationManagerSourceStoreError,
            NSMigrationManagerDestinationStoreError].contains(error.code) {
                
                let message = "Migration failed due to error: \(error.localizedDescription)"
                
                logError { message }
                
                throw NSError(domain: error.domain, code: error.code, userInfo: [NSLocalizedDescriptionKey: message])
                
        } catch let error as NSError {
            
            let message = "Failed to attached persistent store: \(error.localizedDescription)"
            
            logError { message }
            
            throw  NSError(domain: error.domain, code: error.code, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
    
    private func deleteIfExists(path: String) throws {
        
        let fileManager = NSFileManager.defaultManager()
        
        if fileManager.fileExistsAtPath(path) {
            
            logInfo(tag) { "Removing file \(path)." }
            
            try fileManager.removeItemAtPath(path)
        }
    }
    
    private dynamic func handleContextDidSaveNotification(notification: NSNotification)  {
        
        if let context = notification.object as? NSManagedObjectContext {
            
            //
            // If the saved context has it's parent set to our 
            // mainThreadContext auto save the main context
            //
            if context.parentContext == mainContext {
                
                mainContext.performBlock( { () -> Void in
                    do {
                        try self.mainContext.save()
                    } catch let error as NSError {
                        self.errorHandlerBlock(error: error)
                    }
                })
            }
        }
    }
}
