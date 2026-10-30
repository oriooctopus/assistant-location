#import "ClipsTakesStore.h"

#import "GLDurableOutbox.h"

static NSString *const kAlignKind = @"clip-take-align";
/// Map points are about 0.5s apart (location-server/lib/clipAlign.mjs), so a wider
/// spacing is a real gap: that stretch of the take was not placed in the song.
static const NSTimeInterval kMaxPointGap = 1.5;
/// Neighbouring points further apart than this in the song are a jump (a restart),
/// and interpolating across one would invent a position never played.
static const NSTimeInterval kMaxSongStep = 3;
/// How far a song time may sit from the nearest point and still count as played.
static const NSTimeInterval kSongMatchTolerance = 1;

@interface ClipsTakesStore ()
@property (nonatomic, strong) NSURL *directory;
@property (nonatomic, copy) GLDurableOutbox *_Nullable (^outboxProvider)(void);
@end

@implementation ClipsTakesStore

- (instancetype)initWithDirectory:(NSURL *)directory outbox:(GLDurableOutbox *_Nullable (^)(void))outbox {
    self = [super init];
    if (self) {
        _directory = [directory URLByAppendingPathComponent:@"Takes" isDirectory:YES];
        _outboxProvider = [outbox copy];
        NSError *error = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtURL:_directory withIntermediateDirectories:YES attributes:nil error:&error]) {
            [NSException raise:NSInternalInconsistencyException format:@"Clips: cannot create %@: %@", _directory, error];
        }
    }
    return self;
}

- (NSURL *)listFileForClip:(NSString *)clipID {
    return [self.directory URLByAppendingPathComponent:[NSString stringWithFormat:@"takes-%@.json", clipID]];
}

- (NSURL *)fileURLForTakeID:(NSString *)takeID {
    return [self.directory URLByAppendingPathComponent:[takeID stringByAppendingPathExtension:@"m4a"]];
}

- (NSURL *)fileURLForTake:(NSDictionary *)take { return [self fileURLForTakeID:take[@"id"]]; }

- (NSURL *)newRecordingURL { return [self fileURLForTakeID:[NSUUID UUID].UUIDString]; }

- (NSArray<NSDictionary *> *)takesForClip:(NSString *)clipID {
    NSData *data = [NSData dataWithContentsOfURL:[self listFileForClip:clipID]];
    if (!data) return @[];
    NSError *error = nil;
    NSArray *takes = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![takes isKindOfClass:[NSArray class]]) {
        [NSException raise:NSInternalInconsistencyException format:@"Clips: takes file for %@ is invalid: %@", clipID, error];
    }
    return takes;
}

- (void)saveTakes:(NSArray<NSDictionary *> *)takes forClip:(NSString *)clipID {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:takes options:0 error:&error];
    if (!data || ![data writeToURL:[self listFileForClip:clipID] options:NSDataWritingAtomic error:&error]) {
        [NSException raise:NSInternalInconsistencyException format:@"Clips: cannot save takes for %@: %@", clipID, error];
    }
}

- (NSDictionary *)addTakeAtURL:(NSURL *)url toClip:(NSString *)clipID duration:(NSTimeInterval)duration {
    NSString *takeID = url.lastPathComponent.stringByDeletingPathExtension;
    NSDictionary *take = @{@"id": takeID, @"created": @([NSDate date].timeIntervalSince1970), @"duration": @(duration)};
    NSMutableArray *takes = [[self takesForClip:clipID] mutableCopy];
    [takes insertObject:take atIndex:0];
    [self saveTakes:takes forClip:clipID];

    GLDurableOutbox *outbox = self.outboxProvider();
    if (!outbox) return take;
    NSError *error = nil;
    NSData *body = [NSData dataWithContentsOfURL:url options:0 error:&error];
    if (!body) [NSException raise:NSInternalInconsistencyException format:@"Clips: cannot read take %@: %@", takeID, error];
    // keepResult: the answer has to survive until -saveFinishedAlignments reads it,
    // which may be a later launch when the take was recorded offline.
    NSString *itemID = [outbox enqueueKind:kAlignKind
                                      path:[NSString stringWithFormat:@"/clips/%@/align", clipID]
                                   headers:@{@"Content-Type": @"audio/mp4"}
                                      body:body
                                      meta:@{@"clip": clipID, @"take": takeID}
                                keepResult:YES
                          acceptedStatuses:nil
                            retryTransient:YES
                                     error:&error];
    if (!itemID) [NSException raise:NSInternalInconsistencyException format:@"Clips: cannot queue take %@: %@", takeID, error];
    return take;
}

- (void)deleteTake:(NSString *)takeID inClip:(NSString *)clipID {
    NSPredicate *keep = [NSPredicate predicateWithFormat:@"id != %@", takeID];
    [self saveTakes:[[self takesForClip:clipID] filteredArrayUsingPredicate:keep] forClip:clipID];
    NSError *error = nil;
    if (![[NSFileManager defaultManager] removeItemAtURL:[self fileURLForTakeID:takeID] error:&error]) {
        NSLog(@"Clips: could not delete the file of take %@: %@", takeID, error);
    }
    GLDurableOutbox *outbox = self.outboxProvider();
    for (NSDictionary *item in outbox.items) {
        if ([item[@"kind"] isEqualToString:kAlignKind] && [item[@"meta"][@"take"] isEqualToString:takeID]) [outbox removeItemID:item[@"id"]];
    }
}

/// Moves each finished answer onto its take. A rejected upload (the box refused
/// the audio) is dropped and logged: the take stays playable, just unplaced.
- (void)saveFinishedAlignmentsForClip:(NSString *)clipID {
    GLDurableOutbox *outbox = self.outboxProvider();
    NSMutableArray<NSDictionary *> *takes = [[self takesForClip:clipID] mutableCopy];
    BOOL changed = NO;
    for (NSDictionary *item in outbox.items) {
        if (![item[@"kind"] isEqualToString:kAlignKind] || ![item[@"meta"][@"clip"] isEqualToString:clipID]) continue;
        if ([item[@"state"] isEqualToString:GLDurableOutboxStateRejected]) {
            NSLog(@"Clips: align rejected for take %@: status %@ %@", item[@"meta"][@"take"], item[@"rejectedStatus"], item[@"lastError"]);
            [outbox removeItemID:item[@"id"]];
            continue;
        }
        if (![item[@"state"] isEqualToString:GLDurableOutboxStateCompleted]) continue;
        NSData *result = [outbox resultDataForItemID:item[@"id"]];
        NSError *error = nil;
        NSDictionary *answer = result ? [NSJSONSerialization JSONObjectWithData:result options:0 error:&error] : nil;
        if (![answer isKindOfClass:[NSDictionary class]] || ![answer[@"map"] isKindOfClass:[NSArray class]]) {
            [NSException raise:NSInternalInconsistencyException format:@"Clips: bad align answer for take %@: %@", item[@"meta"][@"take"], error];
        }
        for (NSUInteger i = 0; i < takes.count; i++) {
            if (![takes[i][@"id"] isEqualToString:item[@"meta"][@"take"]]) continue;
            NSMutableDictionary *take = [takes[i] mutableCopy];
            take[@"map"] = answer[@"map"];
            takes[i] = take;
            changed = YES;
        }
        [outbox removeItemID:item[@"id"]];
    }
    if (changed) [self saveTakes:takes forClip:clipID];
}

- (void)syncAlignmentsForClip:(NSString *)clipID completion:(void (^)(void))completion {
    GLDurableOutbox *outbox = self.outboxProvider();
    if (!outbox) {
        completion();
        return;
    }
    [outbox flushWithCompletion:^{
        [self saveFinishedAlignmentsForClip:clipID];
        completion();
    }];
}

+ (NSNumber *)songTimeForTakeTime:(NSTimeInterval)takeTime inMap:(NSArray<NSArray<NSNumber *> *> *)map {
    NSArray<NSNumber *> *before = nil, *after = nil;
    for (NSArray<NSNumber *> *point in map) {
        if (point[0].doubleValue <= takeTime) before = point;
        else { after = point; break; }
    }
    double beforeGap = before ? takeTime - before[0].doubleValue : INFINITY;
    double afterGap = after ? after[0].doubleValue - takeTime : INFINITY;
    if (before && after && beforeGap + afterGap <= kMaxPointGap
        && fabs(after[1].doubleValue - before[1].doubleValue) <= kMaxSongStep) {
        double fraction = beforeGap / (beforeGap + afterGap);
        return @(before[1].doubleValue + fraction * (after[1].doubleValue - before[1].doubleValue));
    }
    // Just outside a placed stretch, or at a jump: take the closer side rather than blending two places.
    if (MIN(beforeGap, afterGap) > kMaxPointGap / 2) return nil;
    return beforeGap <= afterGap ? before[1] : after[1];
}

+ (NSNumber *)takeTimeForSongTime:(NSTimeInterval)songTime inMap:(NSArray<NSArray<NSNumber *> *> *)map {
    NSNumber *best = nil;
    double bestDistance = kSongMatchTolerance;
    for (NSArray<NSNumber *> *point in map) {
        double distance = fabs(point[1].doubleValue - songTime);
        // Strictly closer only: when a take played a passage several times, the first attempt wins ties.
        if (distance < bestDistance) {
            bestDistance = distance;
            best = point[0];
        }
    }
    return best;
}

@end
