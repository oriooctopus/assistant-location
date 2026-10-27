#import "ClipsSectionsStore.h"

#import "GLDurableOutbox.h"

static NSString *const kSectionsKind = @"clip-sections";

@interface ClipsSectionsStore ()
@property (nonatomic, strong) NSURL *directory;
@property (nonatomic, copy) GLDurableOutbox *_Nullable (^outboxProvider)(void);
@end

@implementation ClipsSectionsStore

- (instancetype)initWithDirectory:(NSURL *)directory outbox:(GLDurableOutbox *_Nullable (^)(void))outbox {
    self = [super init];
    if (self) {
        _directory = directory;
        _outboxProvider = [outbox copy];
    }
    return self;
}

- (NSURL *)fileForClip:(NSString *)clipID {
    return [self.directory URLByAppendingPathComponent:[NSString stringWithFormat:@"sections-%@.json", clipID]];
}

- (NSArray<NSDictionary *> *)sectionsForClip:(NSString *)clipID {
    NSData *data = [NSData dataWithContentsOfURL:[self fileForClip:clipID]];
    if (!data) return @[];
    NSError *error = nil;
    NSArray *sections = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![sections isKindOfClass:[NSArray class]]) {
        [NSException raise:NSInternalInconsistencyException format:@"Clips: sections file for %@ is invalid: %@", clipID, error];
    }
    return sections;
}

- (void)saveSections:(NSArray<NSDictionary *> *)sections forClip:(NSString *)clipID {
    NSArray *sorted = [sections sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"start"] compare:b[@"start"]];
    }];
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:sorted options:0 error:&error];
    if (!data || ![data writeToURL:[self fileForClip:clipID] options:NSDataWritingAtomic error:&error]) {
        [NSException raise:NSInternalInconsistencyException format:@"Clips: cannot save sections for %@: %@", clipID, error];
    }
}

/// Disk first, then the queue. The queued body is the whole list, and the
/// outbox replays oldest first, so the newest write is what the box ends with.
- (void)commit:(NSArray<NSDictionary *> *)sections forClip:(NSString *)clipID {
    [self saveSections:sections forClip:clipID];
    GLDurableOutbox *outbox = self.outboxProvider();
    if (!outbox) return;
    NSData *body = [NSJSONSerialization dataWithJSONObject:[self sectionsForClip:clipID] options:0 error:nil];
    NSError *error = nil;
    NSString *itemID = [outbox enqueueKind:kSectionsKind
                                      path:[NSString stringWithFormat:@"/clips/%@/sections", clipID]
                                   headers:@{@"Content-Type": @"application/json"}
                                      body:body
                                      meta:@{@"clip": clipID}
                                keepResult:NO
                          acceptedStatuses:nil
                            retryTransient:YES
                                     error:&error];
    if (!itemID) {
        [NSException raise:NSInternalInconsistencyException format:@"Clips: cannot queue sections for %@: %@", clipID, error];
    }
    [outbox flushWithCompletion:nil];
}

- (NSDictionary *)addSectionToClip:(NSString *)clipID name:(NSString *)name start:(NSTimeInterval)start end:(NSTimeInterval)end {
    NSDictionary *section = @{@"id": [NSUUID UUID].UUIDString, @"name": name, @"start": @(start), @"end": @(end)};
    [self commit:[[self sectionsForClip:clipID] arrayByAddingObject:section] forClip:clipID];
    return section;
}

- (void)updateSection:(NSString *)sectionID inClip:(NSString *)clipID
                 name:(NSString *)name start:(NSNumber *)start end:(NSNumber *)end {
    NSMutableArray *sections = [NSMutableArray array];
    for (NSDictionary *s in [self sectionsForClip:clipID]) {
        NSMutableDictionary *copy = [s mutableCopy];
        if ([s[@"id"] isEqualToString:sectionID]) {
            if (name) copy[@"name"] = name;
            if (start) copy[@"start"] = start;
            if (end) copy[@"end"] = end;
        }
        [sections addObject:copy];
    }
    [self commit:sections forClip:clipID];
}

- (void)deleteSection:(NSString *)sectionID inClip:(NSString *)clipID {
    NSPredicate *keep = [NSPredicate predicateWithFormat:@"id != %@", sectionID];
    [self commit:[[self sectionsForClip:clipID] filteredArrayUsingPredicate:keep] forClip:clipID];
}

- (BOOL)hasUnsyncedWritesForClip:(NSString *)clipID {
    GLDurableOutbox *outbox = self.outboxProvider();
    for (NSDictionary *item in outbox.items) {
        if ([item[@"kind"] isEqualToString:kSectionsKind] && [item[@"meta"][@"clip"] isEqualToString:clipID]
            && ![item[@"state"] isEqualToString:GLDurableOutboxStateCompleted]) return YES;
    }
    return NO;
}

- (void)adoptServerSections:(NSArray<NSDictionary *> *)sections forClip:(NSString *)clipID {
    if ([self hasUnsyncedWritesForClip:clipID]) return;
    [self saveSections:sections forClip:clipID];
}

+ (NSDictionary *)sectionForReference:(NSString *)reference inSections:(NSArray<NSDictionary *> *)sections {
    for (NSDictionary *s in sections) if ([s[@"id"] isEqualToString:reference]) return s;
    NSScanner *scanner = [NSScanner scannerWithString:reference];
    NSInteger position = 0;
    if ([scanner scanInteger:&position] && scanner.isAtEnd && position >= 1 && position <= (NSInteger)sections.count) {
        return sections[position - 1];
    }
    return nil;
}

@end
