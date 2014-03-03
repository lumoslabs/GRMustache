// The MIT License
//
// Copyright (c) 2014 Gwendal Roué
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import <objc/message.h>
#import <pthread.h>
#import "GRMustacheKeyAccess_private.h"
#import "GRMustacheKeyValidation.h"
#import "JRSwizzle.h"


#if !defined(NS_BLOCK_ASSERTIONS)
// For testing purpose
BOOL GRMustacheKeyAccessDidCatchNSUndefinedKeyException;
#endif


// =============================================================================
#pragma mark - NSUndefinedKeyException prevention declarations

@interface NSObject(GRMustacheKeyAccessPreventionOfNSUndefinedKeyException)
- (id)GRMustacheKeyAccessValueForUndefinedKey_NSObject:(NSString *)key;
- (id)GRMustacheKeyAccessValueForUndefinedKey_NSManagedObject:(NSString *)key;
@end;


// =============================================================================
#pragma mark - GRMustacheKeyAccess

static Class NSOrderedSetClass;

@interface NSObject(GRMustacheCoreDataMethods)
- (NSDictionary *)propertiesByName;
- (id)entity;
@end

@implementation GRMustacheKeyAccess

+ (void)initialize
{
    NSOrderedSetClass = NSClassFromString(@"NSOrderedSet");
}

+ (id)valueForMustacheKey:(NSString *)key inObject:(id)object
{
    if (object == nil) {
        return nil;
    }
    
    
    // Try objectForKeyedSubscript: first (see https://github.com/groue/GRMustache/issues/66:)
    
    if ([object respondsToSelector:@selector(objectForKeyedSubscript:)]) {
        return [object objectForKeyedSubscript:key];
    }
    
    
    // Then try valueForKey:, after key validation
    
    if (![self isValidMustacheKey:key forObject:object]) {
        NSLog(@"GRMustache can not access key `%@` on class %@.", key, [object class]);
        return nil;
    }
    
    
    @try {
        
        // valueForKey: may throw NSUndefinedKeyException, and user may want to
        // prevent them.
        
        if (preventsNSUndefinedKeyException) {
            [GRMustacheKeyAccess startPreventingNSUndefinedKeyExceptionFromObject:object];
        }
        
        // We don't want to use NSArray, NSSet and NSOrderedSet implementation
        // of valueForKey:, because they return another collection: see issue
        // #21 and "anchored key should not extract properties inside an array"
        // test in src/tests/Public/v4.0/GRMustacheSuites/compound_keys.json
        //
        // Instead, we want the behavior of NSObject's implementation of valueForKey:.
        
        if ([self objectIsFoundationCollectionWhoseImplementationOfValueForKeyReturnsAnotherCollection:object]) {
            return [self valueForKey:key inFoundationCollectionObject:object];
        } else {
            return [object valueForKey:key];
        }
    }
    
    @catch (NSException *exception) {
        
        // Swallow NSUndefinedKeyException only
        
        if (![[exception name] isEqualToString:NSUndefinedKeyException]) {
            [exception raise];
        }
#if !defined(NS_BLOCK_ASSERTIONS)
        else {
            // For testing purpose
            GRMustacheKeyAccessDidCatchNSUndefinedKeyException = YES;
        }
#endif
    }
    
    @finally {
        if (preventsNSUndefinedKeyException) {
            [GRMustacheKeyAccess stopPreventingNSUndefinedKeyExceptionFromObject:object];
        }
    }
    
    return nil;
}


// =============================================================================
#pragma mark - Foundation collections

+ (BOOL)objectIsFoundationCollectionWhoseImplementationOfValueForKeyReturnsAnotherCollection:(id)object
{
    if ([object isKindOfClass:[NSArray class]]) { return YES; }
    if ([object isKindOfClass:[NSSet class]]) { return YES; }
    if (NSOrderedSetClass && [object isKindOfClass:NSOrderedSetClass]) { return YES; }
    return NO;
}

+ (id)valueForKey:(NSString *)key inFoundationCollectionObject:(id)object
{
    // Ideally, we would use NSObject's implementation for collections, so that
    // we can access properties such as `count`, `anyObject`, etc.
    //
    // And so we did, until [issue #70](https://github.com/groue/GRMustache/issues/70)
    // revealed that the direct use of NSObject's imp crashes on arm64:
    //
    //     IMP imp = class_getMethodImplementation([NSObject class], @selector(valueForKey:));
    //     return imp(object, @selector(valueForKey:), key);    // crash on arm64
    //
    // objc_msgSendSuper fails on arm64 as well:
    //
    //     return objc_msgSendSuper(
    //              &(struct objc_super){ .receiver = object, .super_class = [NSObject class] },
    //              @selector(valueForKey:),
    //              key);    // crash on arm64
    //
    // So we have to implement NSObject's valueForKey: ourselves.
    //
    // Quoting Apple documentation:
    // https://developer.apple.com/library/ios/documentation/Cocoa/Conceptual/KeyValueCoding/Articles/SearchImplementation.html
    //
    // > Default Search Pattern for valueForKey:
    // >
    // > 1. Searches the class of the receiver for an accessor method whose
    // > name matches the pattern get<Key>, <key>, or is<Key>, in that order.
    //
    // The remaining of the search pattern goes into aggregates and ivars. Let's
    // ignore aggregates (until someone has a need for it), and ivars (since
    // they are private).
    
    NSString *keyWithUppercaseInitial = [NSString stringWithFormat:@"%@%@",
                                         [[key substringToIndex:1] uppercaseString],
                                         [key substringFromIndex:1]];
    NSArray *accessors = [NSArray arrayWithObjects:
                          [NSString stringWithFormat:@"get%@", keyWithUppercaseInitial],
                          key,
                          [NSString stringWithFormat:@"is%@", keyWithUppercaseInitial],
                          nil];
    
    for (NSString *accessor in accessors) {
        SEL selector = NSSelectorFromString(accessor);
        if ([object respondsToSelector:selector]) {
            
            // Extract the raw value into a buffer
            
            NSMethodSignature *methodSignature = [object methodSignatureForSelector:selector];
            NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:methodSignature];
            invocation.selector = selector;
            [invocation invokeWithTarget:object];
            void *buffer = malloc([methodSignature methodReturnLength]);
            [invocation getReturnValue:buffer];
            
            // Turn the raw value buffer into an object
            
            id result = nil;
            const char *objCType = [methodSignature methodReturnType];
            switch(objCType[0]) {
                case 'c':
                    result = [NSNumber numberWithChar:*(char *)buffer];
                    break;
                case 'i':
                    result = [NSNumber numberWithInt:*(int *)buffer];
                    break;
                case 's':
                    result = [NSNumber numberWithShort:*(short *)buffer];
                    break;
                case 'l':
                    result = [NSNumber numberWithLong:*(long *)buffer];
                    break;
                case 'q':
                    result = [NSNumber numberWithLongLong:*(long long *)buffer];
                    break;
                case 'C':
                    result = [NSNumber numberWithUnsignedChar:*(unsigned char *)buffer];
                    break;
                case 'I':
                    result = [NSNumber numberWithUnsignedInt:*(unsigned int *)buffer];
                    break;
                case 'S':
                    result = [NSNumber numberWithUnsignedShort:*(unsigned short *)buffer];
                    break;
                case 'L':
                    result = [NSNumber numberWithUnsignedLong:*(unsigned long *)buffer];
                    break;
                case 'Q':
                    result = [NSNumber numberWithUnsignedLongLong:*(unsigned long long *)buffer];
                    break;
                case 'B':
                    result = [NSNumber numberWithBool:*(_Bool *)buffer];
                    break;
                case 'f':
                    result = [NSNumber numberWithFloat:*(float *)buffer];
                    break;
                case 'd':
                    result = [NSNumber numberWithDouble:*(double *)buffer];
                    break;
                case '@':
                case '#':
                    result = *(id *)buffer;
                    break;
                default:
                    [NSException raise:NSInternalInconsistencyException format:@"Not implemented yet"];
                    break;
            }
            
            free(buffer);
            return result;
        }
    }
    
    return nil;
}


// =============================================================================
#pragma mark - Key validation

+ (BOOL)isValidMustacheKey:(NSString *)key forObject:(id)object
{
    if ([object respondsToSelector:@selector(isValidMustacheKey:)]) {
        return [object isValidMustacheKey:key];
    }
    
    static NSMutableDictionary *validKeysForClassName;
    static Class NSManagedObjectClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        validKeysForClassName = [[NSMutableDictionary alloc] init];
        NSManagedObjectClass = NSClassFromString(@"NSManagedObject");
    });
    
    NSMutableSet *validKeys = nil;
    @synchronized(validKeysForClassName) {
        Class klass = [object class];
        NSString *className = NSStringFromClass(klass);
        validKeys = [validKeysForClassName objectForKey:className];
        if (!validKeys) {
            validKeys = [self propertyGettersForClass:klass];
            if (NSManagedObjectClass && [object isKindOfClass:NSManagedObjectClass]) {
                [validKeys unionSet:[NSSet setWithArray:[[[object entity] propertiesByName] allKeys]]];
            }
            [validKeysForClassName setObject:validKeys forKey:className];
        }
    }
    
    return [validKeys containsObject:key];
}

+ (NSMutableSet *)propertyGettersForClass:(Class)klass
{
    NSMutableSet *validKeys = [NSMutableSet set];
    while (klass) {
        // Iterate properties
        
        unsigned int count;
        objc_property_t *properties = class_copyPropertyList(klass, &count);
        
        for (unsigned int i=0; i<count; ++i) {
            const char *attrs = property_getAttributes(properties[i]);
            
            // Valid Mustache keys are property name, and custom getter.
            
            const char *propertyNameCString = property_getName(properties[i]);
            NSString *propertyName = [NSString stringWithCString:propertyNameCString encoding:NSUTF8StringEncoding];
            [validKeys addObject:propertyName];
            
            char *getterStart = strstr(attrs, ",G");            // ",GcustomGetter,..." or NULL if there is no custom getter
            if (getterStart) {
                getterStart += 2;                               // "customGetter,..."
                char *getterEnd = strstr(getterStart, ",");     // ",..." or NULL if customGetter is the last attribute
                size_t getterLength = (getterEnd ? getterEnd : attrs + strlen(attrs)) - getterStart;
                NSString *customGetter = [[[NSString alloc] initWithBytes:getterStart length:getterLength encoding:NSUTF8StringEncoding] autorelease];
                [validKeys addObject:customGetter];
            }
        }
        
        free(properties);
        klass = class_getSuperclass(klass);
    }
    
    return validKeys;
}


// =============================================================================
#pragma mark - NSUndefinedKeyException prevention

static BOOL preventsNSUndefinedKeyException = NO;

#if TARGET_OS_IPHONE
// iOS never had support for Garbage Collector.
// Use fast pthread library.
static pthread_key_t GRPreventedObjectsStorageKey;
void freePreventedObjectsStorage(void *objects) {
    [(NSMutableSet *)objects release];
}
#define setupPreventedObjectsStorage() pthread_key_create(&GRPreventedObjectsStorageKey, freePreventedObjectsStorage)
#define getCurrentThreadPreventedObjects() (NSMutableSet *)pthread_getspecific(GRPreventedObjectsStorageKey)
#define setCurrentThreadPreventedObjects(objects) pthread_setspecific(GRPreventedObjectsStorageKey, objects)
#else
// OSX used to have support for Garbage Collector.
// Use slow NSThread library.
static NSString *GRPreventedObjectsStorageKey = @"GRPreventedObjectsStorageKey";
#define setupPreventedObjectsStorage()
#define getCurrentThreadPreventedObjects() (NSMutableSet *)[[[NSThread currentThread] threadDictionary] objectForKey:GRPreventedObjectsStorageKey]
#define setCurrentThreadPreventedObjects(objects) [[[NSThread currentThread] threadDictionary] setObject:objects forKey:GRPreventedObjectsStorageKey]
#endif

+ (void)preventNSUndefinedKeyExceptionAttack
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [self setupNSUndefinedKeyExceptionPrevention];
    });
}

+ (void)setupNSUndefinedKeyExceptionPrevention
{
    preventsNSUndefinedKeyException = YES;
    
    // Swizzle [NSObject valueForUndefinedKey:]
    
    [NSObject jr_swizzleMethod:@selector(valueForUndefinedKey:)
                    withMethod:@selector(GRMustacheKeyAccessValueForUndefinedKey_NSObject:)
                         error:nil];
    
    
    // Swizzle [NSManagedObject valueForUndefinedKey:]
    
    Class NSManagedObjectClass = NSClassFromString(@"NSManagedObject");
    if (NSManagedObjectClass) {
        [NSManagedObjectClass jr_swizzleMethod:@selector(valueForUndefinedKey:)
                                    withMethod:@selector(GRMustacheKeyAccessValueForUndefinedKey_NSManagedObject:)
                                         error:nil];
    }
    
    setupPreventedObjectsStorage();
}

+ (void)startPreventingNSUndefinedKeyExceptionFromObject:(id)object
{
    NSMutableSet *objects = getCurrentThreadPreventedObjects();
    if (objects == NULL) {
        // objects will be released by the garbage collector, or by pthread
        // destructor function freePreventedObjectsStorage.
        //
        // Static analyzer can't see that, and emits a memory leak warning here.
        // This is a false positive: avoid the static analyzer examine this
        // portion of code.
#ifndef __clang_analyzer__
        objects = [[NSMutableSet alloc] init];
        setCurrentThreadPreventedObjects(objects);
#endif
    }
    
    [objects addObject:object];
}

+ (void)stopPreventingNSUndefinedKeyExceptionFromObject:(id)object
{
    [getCurrentThreadPreventedObjects() removeObject:object];
}

@end

@implementation NSObject(GRMustacheKeyAccessPreventionOfNSUndefinedKeyException)

// NSObject
- (id)GRMustacheKeyAccessValueForUndefinedKey_NSObject:(NSString *)key
{
    if ([getCurrentThreadPreventedObjects() containsObject:self]) {
        return nil;
    }
    return [self GRMustacheKeyAccessValueForUndefinedKey_NSObject:key];
}

// NSManagedObject
- (id)GRMustacheKeyAccessValueForUndefinedKey_NSManagedObject:(NSString *)key
{
    if ([getCurrentThreadPreventedObjects() containsObject:self]) {
        return nil;
    }
    return [self GRMustacheKeyAccessValueForUndefinedKey_NSManagedObject:key];
}

@end