#import "CycleStore.h"

NSString *const CycleStoreErrorDomain = @"CycleStore";

@interface CycleStore ()
@property (nonatomic, strong) NSURL *fileURL;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *values;
@end

@implementation CycleStore

- (instancetype)initWithDirectory:(NSURL *)directory error:(NSError **)error {
    if ((self = [super init])) {
        _fileURL = [directory URLByAppendingPathComponent:@"cycle-store.json"];
        NSData *data = [NSData dataWithContentsOfURL:_fileURL options:0 error:NULL];
        if (!data) {
            if ([NSFileManager.defaultManager fileExistsAtPath:_fileURL.path]) {
                if (error) *error = [NSError errorWithDomain:CycleStoreErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"store file exists but cannot be read: %@", _fileURL.path]}];
                return nil;
            }
            _values = [NSMutableDictionary dictionary];
            return self;
        }
        NSError *parseError = nil;
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&parseError];
        if (![parsed isKindOfClass:NSMutableDictionary.class]) {
            if (error) *error = [NSError errorWithDomain:CycleStoreErrorDomain code:2 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"store file is not a JSON object (parsed %@, error %@)", NSStringFromClass([parsed class]), parseError]}];
            return nil;
        }
        _values = parsed;
    }
    return self;
}

- (NSString *)valueForKey:(NSString *)key {
    return self.values[key];
}

- (BOOL)setValue:(NSString *)value forKey:(NSString *)key error:(NSError **)error {
    NSString *previous = self.values[key];
    if (value) self.values[key] = value; else [self.values removeObjectForKey:key];
    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.values options:NSJSONWritingSortedKeys error:&jsonError];
    NSError *writeError = nil;
    if (data && [data writeToURL:self.fileURL options:NSDataWritingAtomic error:&writeError]) return YES;
    if (previous) self.values[key] = previous; else [self.values removeObjectForKey:key];
    if (error) *error = [NSError errorWithDomain:CycleStoreErrorDomain code:3 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"store write failed: %@", writeError ?: jsonError]}];
    return NO;
}

- (NSArray<NSString *> *)keysWithPrefix:(NSString *)prefix {
    NSMutableArray *keys = [NSMutableArray array];
    for (NSString *k in self.values) if ([k hasPrefix:prefix]) [keys addObject:k];
    return [keys sortedArrayUsingSelector:@selector(compare:)];
}

@end
