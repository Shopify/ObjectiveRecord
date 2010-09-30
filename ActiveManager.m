//
//  ActiveManager.m
//  Shopify_Mobile
//
//  Created by Matthew Newberry on 8/2/10.
//  Copyright 2010 Shopify. All rights reserved.
//

#import "ActiveManager.h"
#import "ActiveConnection.h"
#import "NSThread+Blocks.m"

#define OR_CORE_DATE_STORE_TYPE		NSSQLiteStoreType
#define OR_CORE_DATE_STORE_NAME		@"CoreData.sqlite"
#define OR_CORE_DATE_BATCH_SIZE		25

static ActiveManager *_shared;

@implementation ActiveManager

@synthesize activeConnection = _activeConnection;
@synthesize remoteContentFormat = _remoteContentFormat;
@synthesize remoteContentType = _remoteContentType;
@synthesize parsingClass = _parsingClass;
@synthesize baseRemoteURL = _baseRemoteURL;
@synthesize connectionClass = _connectionClass;
@synthesize logLevel;
@synthesize defaultDateParser = _defaultDateParser;
@synthesize entityDescriptions = _entityDescriptions;
@synthesize modelProperties = _modelProperties;
@synthesize modelRelationships = _modelRelationships;
@synthesize modelAttributes = _modelAttributes;
@synthesize requestQueue = _requestQueue;
@synthesize managedObjectContext = _managedObjectContext;
@synthesize managedObjectModel = _managedObjectModel;
@synthesize persistentStoreCoordinator = _persistentStoreCoordinator;

+ (ActiveManager *) shared{
	
	if(_shared == nil)
		_shared = [[ActiveManager alloc] init];
	
	return _shared;
}

- (id) init{
	
	return [self initWithManagedObjectContext:nil];
}

- (id) initWithManagedObjectContext:(NSManagedObjectContext *) moc{
	
	if(self = [super init]){
		
		self.requestQueue = [[NSOperationQueue alloc] init];
		self.remoteContentType = @"application/json";
		self.remoteContentFormat = @"json";
		
		self.managedObjectContext = moc == nil ? [self managedObjectContext] : moc;
		self.persistentStoreCoordinator = moc == nil ? [self persistentStoreCoordinator] : [moc persistentStoreCoordinator];
		self.managedObjectModel = moc == nil ? [self managedObjectModel] : [[moc persistentStoreCoordinator] managedObjectModel];
		
		self.defaultDateParser = [[NSDateFormatter alloc] init];
        
		self.entityDescriptions = [NSMutableDictionary dictionary];
        self.modelProperties = [NSMutableDictionary dictionary];
        self.modelRelationships = [NSMutableDictionary dictionary];
		
		self.logLevel = 2;
		
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(managedObjectContextDidSave:) name:NSManagedObjectContextDidSaveNotification object:moc];
	}
	
	return self;
}

- (void) setConnectionClass:(id)activeConnectionClass{
	
	_connectionClass = activeConnectionClass;
	
	_activeConnection = [_connectionClass new];
}

- (void) addRequest:(ActiveRequest *) request{
	
	[self addRequest:request delegate:request.delegate didFinishSelector:nil didFailSelector:nil];
}

- (void) addRequest:(ActiveRequest *) request delegate:(id) delegate didFinishSelector:(SEL)didFinishSelector didFailSelector:(SEL)didFailSelector{
	
	[request setUrlPath:[[ActiveManager shared].baseRemoteURL stringByAppendingString:request.urlPath]];
	request.didFailSelector = didFailSelector;
	request.didFinishSelector = didFinishSelector;
	request.delegate = delegate;
	
	NSInvocationOperation <ActiveConnection> *operation = [[NSInvocationOperation alloc] initWithTarget:_activeConnection selector:@selector(send:) object:request];
	[_requestQueue addOperation:operation];
	[operation release];
}

- (void) addRequest:(ActiveRequest *) request didFinishBlock:(void(^)(ActiveResult *result))didFinishBlock didFailBlock:(void(^)(ActiveResult *result))didFailBlock{
	
	[request setUrlPath:[[ActiveManager shared].baseRemoteURL stringByAppendingString:request.urlPath]];
	
	[NSThread performBlockInBackground:^{
		
		ActiveResult *result = (ActiveResult *) [_activeConnection send:request];
		
		if(result.error == nil && didFinishBlock){
			
			[[NSThread mainThread] performBlock:^{
				didFinishBlock(result);
			}];
		}
		else if(didFailBlock){
			
			[[NSThread mainThread] performBlock:^{
				didFailBlock(result);
			}];
		}
	}];
}

- (NSData *) serializeObject:(id)object{
	
	id <ActiveParser> parser = [[[_parsingClass alloc] init] autorelease];
	NSString *string = [parser parseToString:object];
	
	return [string dataUsingEncoding:NSUTF8StringEncoding];
}




/*	Core Data		*/

- (void) managedObjectContextDidSave:(NSNotification *)notification{
	
	NSManagedObjectContext *moc = [notification object];
	if(moc != [self managedObjectContext])
		[[self managedObjectContext] mergeChangesFromContextDidSaveNotification:notification];		
}

- (NSManagedObjectContext*) managedObjectContext {
	if( _managedObjectContext != nil ) {
		return _managedObjectContext;
	}
	
	NSPersistentStoreCoordinator *coordinator = [self persistentStoreCoordinator];
	if (coordinator != nil) {
		_managedObjectContext = [[NSManagedObjectContext alloc] init];
		[_managedObjectContext setPersistentStoreCoordinator: coordinator];
		[_managedObjectContext setUndoManager:nil];
		[_managedObjectContext setRetainsRegisteredObjects:YES];
	}
	return _managedObjectContext;
}


- (NSManagedObjectModel*) managedObjectModel {
	if( _managedObjectModel != nil ) {
		return _managedObjectModel;
	}
	_managedObjectModel = [[NSManagedObjectModel mergedModelFromBundles:nil] retain];
	return _managedObjectModel;
}


- (NSString*) storePath {
	return [[self applicationDocumentsDirectory]
			stringByAppendingPathComponent: OR_CORE_DATE_STORE_NAME];
}


- (NSURL*) storeUrl {
	return [NSURL fileURLWithPath:[self storePath]];
}


- (NSDictionary*) migrationOptions {
	return nil;
}


- (NSPersistentStoreCoordinator*) persistentStoreCoordinator {
	if( _persistentStoreCoordinator != nil ) {
		return _persistentStoreCoordinator;
	}
	
	NSString* storePath = [self storePath];
	NSURL *storeUrl = [self storeUrl];
	
	NSError* error;
	_persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc]
								  initWithManagedObjectModel: [self managedObjectModel]];
	
	NSDictionary* options = [self migrationOptions];
	
	// Check whether the store already exists or not.
	NSFileManager* fileManager = [NSFileManager defaultManager];
	BOOL exists = [fileManager fileExistsAtPath:storePath];
	
	if(!exists ) {
		_modelCreated = YES;
	} else {
		if( _resetModel ||
		   [[NSUserDefaults standardUserDefaults] boolForKey:@"erase_all_preference"] ) {
			[[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"erase_all_preference"];
			[fileManager removeItemAtPath:storePath error:nil];
			_modelCreated = YES;
		}
	}
	
	if (![_persistentStoreCoordinator
		  addPersistentStoreWithType: OR_CORE_DATE_STORE_TYPE
		  configuration: nil
		  URL: storeUrl
		  options: options
		  error: &error
		  ]) {
		// We couldn't add the persistent store, so let's wipe it out and try again.
		[fileManager removeItemAtPath:storePath error:nil];
		_modelCreated = YES;
		
		if (![_persistentStoreCoordinator
			  addPersistentStoreWithType: OR_CORE_DATE_STORE_TYPE
			  configuration: nil
			  URL: storeUrl
			  options: nil
			  error: &error
			  ]) {
			// Something is terribly wrong here.
		}
	}
	
	return _persistentStoreCoordinator;
}

- (NSString *)applicationDocumentsDirectory {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
}

- (void)dealloc{
	[_requestQueue release];
	[_managedObjectContext release];
	[_managedObjectModel release];
	[_persistentStoreCoordinator release];

	[_defaultDateParser release];
	[_entityDescriptions release];
	[_modelProperties release];
	[_modelRelationships release];
	[_modelAttributes release];
	[_baseRemoteURL release];

	[_parsingClass release];
	[_remoteContentType release];
	[_remoteContentFormat release];
	[_activeConnection release];

	[super dealloc];
}

@end
