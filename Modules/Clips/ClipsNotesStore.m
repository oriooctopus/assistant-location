#import "ClipsNotesStore.h"

#import "GLDurableOutbox.h"

static NSString *const kNotesKind = @"clip-notes";

@interface ClipsNotesStore ()
@property (nonatomic, strong) NSURL *directory;
@property (nonatomic, copy) GLDurableOutbox *_Nullable (^outboxProvider)(void);
@end

@implementation ClipsNotesStore

- (instancetype)initWithDirectory:(NSURL *)directory outbox:(GLDurableOutbox *_Nullable (^)(void))outbox {
    self = [super init];
    if (self) {
        _directory = directory;
        _outboxProvider = [outbox copy];
    }
    return self;
}

- (NSURL *)fileForClip:(NSString *)clipID {
    return [self.directory URLByAppendingPathComponent:[NSString stringWithFormat:@"notes-%@.json", clipID]];
}

- (NSArray<NSDictionary *> *)notesForClip:(NSString *)clipID {
    NSData *data = [NSData dataWithContentsOfURL:[self fileForClip:clipID]];
    if (!data) return @[];
    NSError *error = nil;
    NSArray *notes = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![notes isKindOfClass:[NSArray class]]) {
        [NSException raise:NSInternalInconsistencyException format:@"Clips: notes file for %@ is invalid: %@", clipID, error];
    }
    return notes;
}

- (void)saveNotes:(NSArray<NSDictionary *> *)notes forClip:(NSString *)clipID {
    NSArray *sorted = [notes sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"time"] compare:b[@"time"]];
    }];
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:sorted options:0 error:&error];
    if (!data || ![data writeToURL:[self fileForClip:clipID] options:NSDataWritingAtomic error:&error]) {
        [NSException raise:NSInternalInconsistencyException format:@"Clips: cannot save notes for %@: %@", clipID, error];
    }
}

/// Disk first, then the queue. The queued body is the whole list, and the
/// outbox replays oldest first, so the newest write is what the box ends with.
- (void)commit:(NSArray<NSDictionary *> *)notes forClip:(NSString *)clipID {
    [self saveNotes:notes forClip:clipID];
    GLDurableOutbox *outbox = self.outboxProvider();
    if (!outbox) return;
    NSData *body = [NSJSONSerialization dataWithJSONObject:[self notesForClip:clipID] options:0 error:nil];
    NSError *error = nil;
    NSString *itemID = [outbox enqueueKind:kNotesKind
                                      path:[NSString stringWithFormat:@"/clips/%@/notes", clipID]
                                   headers:@{@"Content-Type": @"application/json"}
                                      body:body
                                      meta:@{@"clip": clipID}
                                keepResult:NO
                          acceptedStatuses:nil
                            retryTransient:YES
                                     error:&error];
    if (!itemID) {
        [NSException raise:NSInternalInconsistencyException format:@"Clips: cannot queue notes for %@: %@", clipID, error];
    }
    [outbox flushWithCompletion:nil];
}

- (NSDictionary *)addNoteToClip:(NSString *)clipID time:(NSTimeInterval)time text:(NSString *)text {
    NSDictionary *note = @{@"id": [NSUUID UUID].UUIDString, @"time": @(time), @"text": text};
    [self commit:[[self notesForClip:clipID] arrayByAddingObject:note] forClip:clipID];
    return note;
}

- (void)setText:(NSString *)text ofNote:(NSString *)noteID inClip:(NSString *)clipID {
    NSMutableArray *notes = [NSMutableArray array];
    for (NSDictionary *n in [self notesForClip:clipID]) {
        NSMutableDictionary *copy = [n mutableCopy];
        if ([n[@"id"] isEqualToString:noteID]) copy[@"text"] = text;
        [notes addObject:copy];
    }
    [self commit:notes forClip:clipID];
}

- (void)deleteNote:(NSString *)noteID inClip:(NSString *)clipID {
    NSPredicate *keep = [NSPredicate predicateWithFormat:@"id != %@", noteID];
    [self commit:[[self notesForClip:clipID] filteredArrayUsingPredicate:keep] forClip:clipID];
}

- (BOOL)hasUnsyncedWritesForClip:(NSString *)clipID {
    GLDurableOutbox *outbox = self.outboxProvider();
    for (NSDictionary *item in outbox.items) {
        if ([item[@"kind"] isEqualToString:kNotesKind] && [item[@"meta"][@"clip"] isEqualToString:clipID]
            && ![item[@"state"] isEqualToString:GLDurableOutboxStateCompleted]) return YES;
    }
    return NO;
}

- (void)adoptServerNotes:(NSArray<NSDictionary *> *)notes forClip:(NSString *)clipID {
    if ([self hasUnsyncedWritesForClip:clipID]) return;
    [self saveNotes:notes forClip:clipID];
}

@end
