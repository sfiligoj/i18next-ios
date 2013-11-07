//
//  I18Next.m
//  i18next
//
//  Created by Jean Regisser on 28/10/13.
//  Copyright (c) 2013 PrePlay, Inc. All rights reserved.
//

#import "I18Next.h"
#import <objc/runtime.h>
#import "I18NextPlurals.h"
#import "I18NextConnection.h"
#import "NSObject+I18Next.h"
#import "NSString+I18Next.h"

NSString* const kI18NextOptionLang = @"lang";
NSString* const kI18NextOptionLowercaseLang = @"lowercaseLang";
NSString* const kI18NextOptionLangLoadType = @"langLoadType";
NSString* const kI18NextOptionFallbackLang = @"fallbackLang";
NSString* const kI18NextOptionNamespace = @"namespace";
NSString* const kI18NextOptionNamespaces = @"namespaces";
NSString* const kI18NextOptionDefaultNamespace = @"defaultNamespace";
NSString* const kI18NextOptionFallbackToDefaultNamespace = @"fallbackToDefaultNamespace";
NSString* const kI18NextOptionFallbackNamespaces = @"fallbackNamespaces";
NSString* const kI18NextOptionFallbackOnNull = @"fallbackOnNull";
NSString* const kI18NextOptionReturnObjectTrees = @"returnObjectTrees";
NSString* const kI18NextOptionResourcesStore = @"resourcesStore";
NSString* const kI18NextOptionNamespaceSeparator = @"namespaceSeparator";
NSString* const kI18NextOptionKeySeparator = @"keySeparator";
NSString* const kI18NextOptionInterpolationPrefix = @"interpolationPrefix";
NSString* const kI18NextOptionInterpolationSuffix = @"interpolationSuffix";
NSString* const kI18NextOptionPluralSuffix = @"pluralSuffix";

NSString* const kI18NextOptionResourcesBaseURL = @"resourcesBaseURL";
NSString* const kI18NextOptionResourcesGetPathTemplate = @"resourcesGetPathTemplate";

NSString* const kI18NextNamespaceSeparator = @":";
NSString* const kI18NextDefaultNamespace = @"translation";
NSString* const kI18NextPluralSuffix = @"_plural";

NSString* const kI18NextResourcesGetPathTemplate = @"locales/__lng__/__ns__.json";

NSString* const kI18NextTranslateOptionContext = @"context";
NSString* const kI18NextTranslateOptionCount = @"count";
NSString* const kI18NextTranslateOptionVariables = @"variables";
NSString* const kI18NextTranslateOptionDefaultValue = @"defaultValue";
NSString* const kI18NextTranslateOptionSprintf = @"sprintf";

NSString* const I18NextErrorDomain = @"I18NextErrorDomain";
NSString* const I18NextDetailedErrorsKey = @"I18NextDetailedErrorsKey";

static I18Next* gSharedInstance = nil;
static dispatch_once_t gOnceToken;

@interface I18Next ()

@property (nonatomic, copy, readwrite) NSDictionary* options;
@property (nonatomic, strong, readwrite) I18NextOptions* optionsObject;
@property (nonatomic, copy) NSDictionary* resourcesStore;

@property (nonatomic, strong) NSMutableArray* currentConnections;
@property (nonatomic, strong) NSOperationQueue* backgroundQueue;

@end

@implementation I18Next

@dynamic lang;

static NSString* genericTranslate(id self, SEL _cmd, ...) {
    va_list arglist;
    va_start(arglist, _cmd);

    id key = va_arg(arglist, id);
    NSString *selectorName = NSStringFromSelector(_cmd);
    NSArray* argNames = [selectorName componentsSeparatedByString:@":"];
    NSMethodSignature* sig = [self methodSignatureForSelector:_cmd];
    NSMutableDictionary* options = [NSMutableDictionary dictionaryWithCapacity:sig.numberOfArguments - 2];
    // Loop over arguments after key
    for (NSUInteger i = 3; i < sig.numberOfArguments; i++) {
        const char* type = [sig getArgumentTypeAtIndex:i];
        
        id argValue = nil;
        if (strcmp(type, @encode(NSUInteger)) == 0) {
            NSUInteger count = va_arg(arglist, NSUInteger);
            argValue = @(count);
        }
        else if (strcmp(type, @encode(id)) == 0) {
            argValue = va_arg(arglist, id);
        }
        else {
            NSAssert(NO, @"Unsupported argument type: '%s'", type);
        }
        
        if (argValue) {
            options[argNames[i - 2]] = argValue;
        }
    }
    
    va_end(arglist);
    
    return [self t:key options:options];
}

+ (BOOL)resolveInstanceMethod:(SEL)sel {
    NSString *selectorName = NSStringFromSelector(sel);
    NSString *prefix = @"t:";
    if ([selectorName hasPrefix:prefix]) {
        NSArray* args = [selectorName componentsSeparatedByString:@":"];
        NSMutableString* types = [[NSMutableString alloc] initWithString:@"@@:"];
        for (id arg in args) {
            if ([arg isEqualToString:kI18NextTranslateOptionCount]) {
                [types appendFormat:@"%s", @encode(NSUInteger)];
            }
            else {
                [types appendString:@"@"];
            }
        }
        class_addMethod(self, sel, (IMP)genericTranslate, types.UTF8String);
        return YES;
    }
    return [super resolveInstanceMethod:sel];
}

+ (instancetype)sharedInstance {
    dispatch_once(&gOnceToken, ^{
        if (!gSharedInstance) {
            gSharedInstance = [[self alloc] init];
        }
    });
    return gSharedInstance;
}

+ (void)setSharedInstance:(I18Next*)instance {
    gSharedInstance = instance;
    gOnceToken = 0; // resets the once_token so dispatch_once will run again
}

+ (NSString*)t:(id)key {
    return [[self sharedInstance] t:key];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.options = [self defaultOptions];
        
        self.plurals = [I18NextPlurals sharedInstance];
        
        self.backgroundQueue = [[NSOperationQueue alloc] init];
    }
    return self;
}

- (NSString*)lang {
    return self.options[kI18NextOptionLang];
}

- (void)setLang:(NSString *)lang {
    NSMutableDictionary* dict = self.options.mutableCopy;
    dict[kI18NextOptionLang] = lang;
    self.options = dict.copy;
}

- (NSDictionary*)defaultOptions {
    I18NextOptions* options = [I18NextOptions new];
    
    options.fallbackLang = @"dev";
    options.fallbackOnNull = YES;
    options.namespace = @"translation";
    options.namespaceSeparator = @":";
    options.keySeparator = kI18NextKeySeparator;
    options.interpolationPrefix = kI18NextInterpolationPrefix;
    options.interpolationSuffix = kI18NextInterpolationSuffix;
    options.pluralSuffix = kI18NextPluralSuffix;
    options.resourcesGetPathTemplate = kI18NextResourcesGetPathTemplate;
    
    return options.asDictionary;
}

- (void)loadWithOptions:(NSDictionary*)options completion:(void (^)(NSError* error))completionBlock {
    // TODO: sanitize options
    NSMutableDictionary* dict = self.defaultOptions.mutableCopy;
    [dict addEntriesFromDictionary:options];
    
    self.options = dict;
    self.resourcesStore = self.optionsObject.resourcesStore;
    
    // return immediately if resources store is passed
    if (self.resourcesStore) {
        if (completionBlock) {
            completionBlock(nil);
        }
        return;
    }
    
    NSArray* langs = [self languagesForLang:self.lang];
    [self loadLangs:langs namespaces:self.optionsObject.namespaces completion:^(NSDictionary *store, NSError *error) {
        self.resourcesStore = store;
        
        if (completionBlock) {
            completionBlock(error);
        }
    }];
}

- (BOOL)exists:(NSString*)key {
    return !![self translateKey:key lang:nil namespace:nil context:nil count:nil variables:nil sprintf:nil defaultValue:nil];
}

- (NSString*)t:(id)key, ... {
    va_list arglist;
    va_start(arglist, key);
    NSString* result = [self t:key options:@{ kI18NextTranslateOptionSprintf: [I18NextSprintfArgs formatBlock:^NSString *(NSString *format) {
        return [I18NextSprintf vsprintf:format arguments:arglist];
    }]
                                              }];
    va_end(arglist);
    
    return result;
}

- (NSString*)t:(id)key options:(NSDictionary*)options {
    NSString* lang = options[kI18NextOptionLang];
    NSString* namespace = options[kI18NextOptionNamespace];
    NSString* context = options[kI18NextTranslateOptionContext];
    NSNumber* count = options[kI18NextTranslateOptionCount];
    NSDictionary* variables = options[kI18NextTranslateOptionVariables];
    NSString* defaultValue = options[kI18NextTranslateOptionDefaultValue];
    I18NextSprintfArgs* sprintfArgs = options[kI18NextTranslateOptionSprintf];
    
    return [self translate:key lang:lang namespace:namespace context:context count:count variables:variables sprintf:sprintfArgs
              defaultValue:defaultValue];
}

#pragma mark Private Methods

- (void)setOptions:(NSDictionary *)options {
    if ([options isEqual:self.options]) {
        return;
    }
    
    _options = options;
    
    self.optionsObject = [I18NextOptions optionsFromDict:options];
}

- (NSArray*)languagesForLang:(NSString*)lang {
    NSMutableArray* languages = [NSMutableArray array];
    
    if (lang.length) {
        // Split languageCode and countryCode
        NSRange dashRange = [lang rangeOfString:@"-"];
        if (dashRange.location != NSNotFound) {
            NSString* languageCode = [lang substringToIndex:dashRange.location].lowercaseString;
            NSString* countryCode = [lang substringFromIndex:dashRange.location + dashRange.length];
            
            countryCode = [self.options[kI18NextOptionLowercaseLang] boolValue] ? countryCode.lowercaseString : countryCode.uppercaseString;
            
            I18NextLangLoadType langLoadType = [self.options[kI18NextOptionLangLoadType] integerValue];
            
            if (langLoadType != I18NextLangLoadTypeUnspecific) {
                [languages addObject:[NSString stringWithFormat:@"%@-%@", languageCode, countryCode]];
            }
            if (langLoadType != I18NextLangLoadTypeCurrent) {
                [languages addObject:languageCode];
            }
        }
        else {
            [languages addObject:lang];
        }
    }
    
    NSString* fallbackLang = self.options[kI18NextOptionFallbackLang];
    if (fallbackLang.length && [languages indexOfObject:fallbackLang] == NSNotFound) {
        [languages addObject:fallbackLang];
    }
    
    return languages;
}

- (void)loadLangs:(NSArray*)langs namespaces:(NSArray*)namespaces completion:(void (^)(NSDictionary* store, NSError* error))completionBlock {
    __block NSMutableDictionary* store = nil;
    
    NSMutableArray* oldConnections = self.currentConnections;
    self.currentConnections = nil;
    [oldConnections makeObjectsPerformSelector:@selector(cancel)];
    
    NSMutableArray* connections = [NSMutableArray array];
    NSMutableArray* errors = [NSMutableArray array];
    for (NSString* lang in langs) {
        for (NSString* ns in namespaces) {
            NSString* getPath = [self.optionsObject.resourcesGetPathTemplate i18n_stringByReplacingVariables:@{ @"lng": lang, @"ns": ns }
                                                                                         interpolationPrefix:self.optionsObject.interpolationPrefix
                                                                                         interpolationSuffix:self.optionsObject.interpolationSuffix];
            NSString* langURLString = [self.optionsObject.resourcesBaseURL.absoluteString
                                       stringByAppendingPathComponent:getPath];
            NSURL* langURL = [NSURL URLWithString:langURLString];
            NSURLRequest* request = [NSURLRequest requestWithURL:langURL];
            
            __block I18NextConnection* connection =
            [I18NextConnection asynchronousRequest:request queue:self.backgroundQueue
                                     completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {
                NSDictionary* json = nil;
                NSError* returnError = error;
                if (!error) {
                    if (data) {
                        NSError* jsonParseError = nil;
                        json = (NSDictionary *)[NSJSONSerialization JSONObjectWithData:data
                                                                               options:kNilOptions
                                                                                 error:&jsonParseError];
                        
                        if (jsonParseError) {
                            // invalid json
                            returnError = [NSError errorWithDomain:I18NextErrorDomain
                                                              code:I18NextErrorInvalidLangData
                                                          userInfo:@{ NSURLErrorFailingURLErrorKey: langURL,
                                                                      NSUnderlyingErrorKey: jsonParseError }];
                        }
                    }
                    else {
                        // no data error
                        returnError = [NSError errorWithDomain:I18NextErrorDomain code:I18NextErrorInvalidLangData
                                                      userInfo:@{ NSURLErrorFailingURLErrorKey: langURL }];
                    }
                }
                                         
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (json) {
                        if (!store) {
                            store = [NSMutableDictionary dictionary];
                        }
                        if (!store[lang]) {
                            store[lang] = [NSMutableDictionary dictionary];
                        }
                        store[lang][ns] = json;
                    }
                    
                    if (returnError) {
                        [errors addObject:returnError];
                    }

                    [connections removeObject:connection];
                    if (connections.count == 0 && completionBlock) {
                        NSError* aggregateError = nil;
                        if (errors.count > 0) {
                            aggregateError = [NSError errorWithDomain:I18NextErrorDomain code:I18NextErrorLoadFailed
                                                             userInfo:@{ I18NextDetailedErrorsKey: errors.copy }];
                        }
                        completionBlock(store, aggregateError);
                    }
                });
            }];
            
            [connections addObject:connection];
        }
        
    }
    
    self.currentConnections = connections;
    [connections makeObjectsPerformSelector:@selector(start)];
}

- (NSString*)translate:(id)key lang:(NSString*)lang namespace:(NSString*)namespace context:(NSString*)context
                 count:(NSNumber*)count variables:(NSDictionary*)variables sprintf:(I18NextSprintfArgs*)sprintf defaultValue:(NSString*)defaultValue {
    NSString* stringKey = nil;
    if ([key isKindOfClass:[NSString class]]) {
        stringKey = key;
    }
    else if ([key isKindOfClass:[NSArray class]]) {
        for (id potentialKey in key) {
            if ([potentialKey isKindOfClass:[NSString class]]) {
                stringKey = potentialKey;
                NSString* value = [self translateKey:potentialKey lang:lang namespace:namespace context:context count:count
                                           variables:variables sprintf:sprintf defaultValue:defaultValue];
                if (value) {
                    return value;
                }
            }
        }
    }
    
    return [self translateKey:stringKey lang:lang namespace:namespace context:context count:count
                    variables:variables sprintf:sprintf defaultValue:defaultValue ?: stringKey];
}

- (NSString*)translateKey:(NSString*)stringKey lang:(NSString*)lang namespace:(NSString*)namespace
                  context:(NSString*)context count:(NSNumber*)count variables:(NSDictionary*)variables
                  sprintf:(I18NextSprintfArgs*)sprintf defaultValue:(NSString*)defaultValue {
    NSString* ns = namespace.length ? namespace : self.options[kI18NextOptionDefaultNamespace];
    NSRange nsRange = [stringKey rangeOfString:self.options[kI18NextOptionNamespaceSeparator]];
    if (nsRange.location != NSNotFound) {
        ns = [stringKey substringToIndex:nsRange.location];
        stringKey = [stringKey substringFromIndex:nsRange.location + nsRange.length];
    }
    
    NSArray* fallbackNamespaces = self.options[kI18NextOptionFallbackNamespaces];
    if (!fallbackNamespaces.count && [self.options[kI18NextOptionFallbackToDefaultNamespace] boolValue]) {
        fallbackNamespaces = @[self.options[kI18NextOptionDefaultNamespace]];
    }
    
    if (context.length) {
        stringKey = [stringKey stringByAppendingFormat:@"_%@", context];
    }
    
    NSMutableDictionary* variablesWithCount = [NSMutableDictionary dictionaryWithDictionary:variables];
    if (count) {
        variablesWithCount[@"count"] = count.stringValue;
        
        NSUInteger countInt = count.unsignedIntegerValue;
        if (countInt != 1) {
            NSString* pluralKey = [stringKey stringByAppendingString:self.options[kI18NextOptionPluralSuffix]];
            NSInteger pluralNumber = [self.plurals numberForLang:(lang.length ? lang : self.options[kI18NextOptionLang]) count:countInt];
            if (pluralNumber >= 0) {
                pluralKey = [pluralKey stringByAppendingFormat:@"_%d", pluralNumber];
            }
//            else if (pluralNumber == 1) {
//                pluralKey = stringKey;
//            }
            
            NSString* value = [self translateKey:pluralKey lang:lang namespace:ns context:nil count:nil
                                       variables:variablesWithCount sprintf:sprintf defaultValue:nil];
            if (value) {
                return value;
            }
            // else continue translation with original/singular key
        }
    }
    
    return [self find:stringKey lang:lang namespace:ns fallbackNamespaces:fallbackNamespaces variables:variablesWithCount
              sprintf:sprintf defaultValue:defaultValue];
}

- (NSString*)find:(NSString*)key lang:(NSString*)lng namespace:(NSString*)ns fallbackNamespaces:(NSArray*)fallbackNamespaces
        variables:(NSDictionary*)variables sprintf:(I18NextSprintfArgs*)sprintf defaultValue:(NSString*)defaultValue {
    id result = nil;
    
    for (id lang in [self languagesForLang:lng.length ? lng : self.lang]) {
        if (![lang isKindOfClass:[NSString class]]) {
            continue;
        }
        
        id value = [self.resourcesStore[lang][ns] i18n_valueForKeyPath:key keySeparator:self.options[kI18NextOptionKeySeparator]];
        if (value) {
            if ([value isKindOfClass:[NSArray class]] && ![self.options[kI18NextOptionReturnObjectTrees] boolValue]) {
                value = [value componentsJoinedByString:@"\n"];
            }
            else if ([value isEqual:[NSNull null]] && [self.options[kI18NextOptionFallbackOnNull] boolValue]) {
                continue;
            }
            else if ([value isKindOfClass:[NSDictionary class]]) {
                if (![self.options[kI18NextOptionReturnObjectTrees] boolValue]) {
                    value = [NSString stringWithFormat:@"key '%@%@%@ (%@)' returned an object instead of a string",
                             ns, self.options[kI18NextOptionNamespaceSeparator], key, lang];
                }
                else {
                    NSMutableDictionary* dict = [NSMutableDictionary dictionaryWithCapacity:((NSDictionary*)value).count];
                    for (id childKey in value) {
                        dict[childKey] = [self translate:[NSString stringWithFormat:@"%@%@%@", key, self.options[kI18NextOptionKeySeparator], childKey]
                                                    lang:lang
                                               namespace:ns context:nil count:nil variables:variables sprintf:sprintf defaultValue:nil];
                    }
                    value = dict.copy;
                }
            }
            result = value;
            break;
        }
    }
    
    // Not found, fallback?
    if (!result && fallbackNamespaces.count) {
        for (NSString* fallbackNS in fallbackNamespaces) {
            id value = [self find:key lang:lng namespace:fallbackNS fallbackNamespaces:nil variables:variables
                          sprintf:sprintf defaultValue:nil];
            if (value) {
                return value;
            }
        }
    }
    
    if (!result) {
        result = defaultValue;
    }
    
    if ([result isKindOfClass:[NSString class]]) {
        result = [result i18n_stringByReplacingVariables:variables
                                     interpolationPrefix:self.options[kI18NextOptionInterpolationPrefix]
                                     interpolationSuffix:self.options[kI18NextOptionInterpolationSuffix]
                                            keySeparator:self.options[kI18NextOptionKeySeparator]];
        
        if(sprintf.formatBlock) {
            result = sprintf.formatBlock(result);
        }
    }
    
    return result;
}

@end

@implementation I18NextOptions

+ (instancetype)optionsFromDict:(NSDictionary*)dict {
    I18NextOptions* options = [self new];
    [options setValuesForKeysWithDictionary:dict];
    return options;
}

- (void)setNamespace:(NSString*)ns {
    self.namespaces = @[ns];
    self.defaultNamespace = ns;
}

- (void)setFallbackNamespace:(NSString*)fallbackNS {
    self.fallbackNamespaces = @[fallbackNS];
}

- (NSDictionary*)asDictionary {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    
    unsigned int count;
    objc_property_t *properties = class_copyPropertyList([self class], &count);
    
    for (int i = 0; i < count; i++) {
        NSString *key = [NSString stringWithUTF8String:property_getName(properties[i])];
        id value = [self valueForKey:key];
        if (value) {
            [dict setObject:value forKey:key];
        }
    }
    
    free(properties);
    
    return [NSDictionary dictionaryWithDictionary:dict];
}

@end

@implementation I18NextSprintfArgs

+ (instancetype)formatBlock:(NSString* (^)(NSString* format))formatBlock {
    I18NextSprintfArgs* args = [I18NextSprintfArgs new];
    args.formatBlock = formatBlock;
    return args;
}

@end

@implementation I18NextSprintf

+ (NSString*)sprintf:(NSString*)format, ... {
    va_list argList;
    va_start(argList, format);
    NSString* result = [[NSString alloc] initWithFormat:format arguments:argList];
    va_end(argList);
    return result;
}

+ (NSString*)vsprintf:(NSString*)format arguments:(va_list)argList {
    return [[NSString alloc] initWithFormat:format arguments:argList];
}

@end
