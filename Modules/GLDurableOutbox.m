#import "GLDurableOutbox.h"

#import <UIKit/UIKit.h>

#import "GLLog.h"

NSString *const GLDurableOutboxDidRejectNotification = @"GLDurableOutboxDidReject";
NSString *const GLDurableOutboxDidQuarantineNotification = @"GLDurableOutboxDidQuarantine";
NSString *const GLDurableOutboxStatePending = @"pending";
NSString *const GLDurableOutboxStateRejected = @"rejected";
NSString *const GLDurableOutboxStateCompleted = @"completed";

// /drop bodies larger than the threshold go to /drop/chunk in kGLDurableChunkSize pieces.
static const unsigned long long kGLDurableChunkThreshold = 2 * 1024 * 1024;
static const unsigned long long kGLDurableChunkSize = 1024 * 1024;

@implementation GLDurableOutbox {
    NSURL *_directory;
    NSURL *(^_urlBuilder)(NSString *);
    NSString *_token;
    NSURLSession *_session;
    dispatch_queue_t _queue;       // serial; owns every field below and all disk access
    BOOL _running;
    BOOL _rerun;
    BOOL _retryScheduled;
    NSMutableArray<void (^)(void)> *_waiters;
}

- (instancetype)initWithDirectory:(NSURL *)directory
                       urlBuilder:(NSURL *(^)(NSString *))urlBuilder
                            token:(NSString *)token
             sessionConfiguration:(NSURLSessionConfiguration *)configuration {
    if ((self = [super init])) {
        _directory = directory;
        _urlBuilder = [urlBuilder copy];
        _token = [token copy];
        _retryInterval = 20;
        _queue = dispatch_queue_create("GLDurableOutbox", DISPATCH_QUEUE_SERIAL);
        _waiters = [NSMutableArray array];
        NSError *error = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
            [NSException raise:NSInternalInconsistencyException format:@"GLDurableOutbox: cannot create %@: %@", directory, error];
        }
        _session = [NSURLSession sessionWithConfiguration:configuration ?: [NSURLSessionConfiguration defaultSessionConfiguration]];
    }
    return self;
}

#pragma mark - Disk (call only on _queue)

static const NSDataWritingOptions kWriteOptions = NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication;

- (NSURL *)manifestURLForID:(NSString *)itemID { return [_directory URLByAppendingPathComponent:[itemID stringByAppendingString:@".json"]]; }
- (NSURL *)bodyURLForID:(NSString *)itemID { return [_directory URLByAppendingPathComponent:[itemID stringByAppendingString:@".body"]]; }
- (NSURL *)resultURLForID:(NSString *)itemID { return [_directory URLByAppendingPathComponent:[itemID stringByAppendingString:@".result"]]; }
- (NSURL *)chunkURLForID:(NSString *)itemID { return [_directory URLByAppendingPathComponent:[itemID stringByAppendingString:@".chunk"]]; }

- (BOOL)writeItem:(NSDictionary *)item error:(NSError **)error {
    NSData *json = [NSJSONSerialization dataWithJSONObject:item options:0 error:error];
    if (!json) return NO;
    return [json writeToURL:[self manifestURLForID:item[@"id"]] options:kWriteOptions error:error];
}

- (void)deleteFilesForID:(NSString *)itemID {
    for (NSURL *url in @[[self manifestURLForID:itemID], [self bodyURLForID:itemID], [self resultURLForID:itemID], [self chunkURLForID:itemID]]) {
        [[NSFileManager defaultManager] removeItemAtURL:url error:NULL];
    }
}

static BOOL GLDurableManifestIsValid(id item) {
    if (![item isKindOfClass:[NSDictionary class]]) return NO;
    for (NSString *key in @[@"id", @"kind", @"path", @"state"]) {
        if (![item[key] isKindOfClass:[NSString class]]) return NO;
    }
    return [item[@"headers"] isKindOfClass:[NSDictionary class]];
}

/// A manifest that can't be read (torn write, disk corruption) must never be
/// skipped silently: its body is the user's content. It is renamed to
/// <id>.json.corrupt (body untouched, so it can be recovered by hand), a
/// notification is posted so the app can say so, and it stops being re-checked.
- (void)quarantineManifestNamed:(NSString *)name {
    NSURL *from = [_directory URLByAppendingPathComponent:name];
    NSURL *to = [_directory URLByAppendingPathComponent:[name stringByAppendingString:@".corrupt"]];
    NSError *error = nil;
    [[NSFileManager defaultManager] removeItemAtURL:to error:NULL];
    if (![[NSFileManager defaultManager] moveItemAtURL:from toURL:to error:&error]) {
        [NSException raise:NSInternalInconsistencyException format:@"GLDurableOutbox: cannot quarantine %@: %@", name, error];
    }
    NSString *itemID = [name stringByDeletingPathExtension];
    GLLog(@"unreadable manifest %@ quarantined as %@; its body is kept", name, to.lastPathComponent);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:GLDurableOutboxDidQuarantineNotification
                                                            object:self
                                                          userInfo:@{@"id": itemID}];
    });
}

/// Oldest first: ids start with a zero-padded millisecond timestamp.
- (NSArray<NSDictionary *> *)loadItems {
    NSArray<NSString *> *names = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:_directory.path error:NULL]
        sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *name in names) {
        if (![name hasSuffix:@".json"]) continue;
        NSData *data = [NSData dataWithContentsOfURL:[_directory URLByAppendingPathComponent:name]];
        id item = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if (!GLDurableManifestIsValid(item)) {
            [self quarantineManifestNamed:name];
            continue;
        }
        [items addObject:item];
    }
    return items;
}

- (NSArray<NSString *> *)quarantinedItemIDs {
    __block NSArray *ids;
    dispatch_sync(_queue, ^{
        NSMutableArray *found = [NSMutableArray array];
        for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self->_directory.path error:NULL]) {
            if ([name hasSuffix:@".json.corrupt"]) [found addObject:[name substringToIndex:name.length - @".json.corrupt".length]];
        }
        ids = [found sortedArrayUsingSelector:@selector(compare:)];
    });
    return ids;
}

/// The pending item to send next: oldest first, except that an item which has
/// failed goes behind items that have not (ordered by when it last failed), so
/// one stuck item never starves the queue.
- (nullable NSDictionary *)oldestPendingItem {
    NSDictionary *best = nil;
    double bestKey = 0;
    for (NSDictionary *item in [self loadItems]) {
        if (![item[@"state"] isEqualToString:GLDurableOutboxStatePending]) continue;
        double key = [item[@"lastAttemptAt"] doubleValue];
        if (!best || key < bestKey) {
            best = item;
            bestKey = key;
        }
    }
    return best;
}

#pragma mark - Public

+ (NSURL *)defaultDirectory {
    NSError *error = nil;
    NSURL *support = [[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory
                                                            inDomain:NSUserDomainMask
                                                   appropriateForURL:nil
                                                              create:YES
                                                               error:&error];
    if (!support) [NSException raise:NSInternalInconsistencyException format:@"no Application Support: %@", error];
    return [support URLByAppendingPathComponent:@"DurableOutbox" isDirectory:YES];
}

- (void)startDraining {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    [self flushWithCompletion:nil];
}

- (void)applicationDidBecomeActive:(NSNotification *)note {
    [self flushWithCompletion:nil];
}

- (NSString *)enqueueKind:(NSString *)kind
                     path:(NSString *)path
                  headers:(NSDictionary<NSString *, NSString *> *)headers
                     body:(NSData *)body
                     meta:(NSDictionary *)meta
               keepResult:(BOOL)keepResult
         acceptedStatuses:(NSArray<NSNumber *> *)acceptedStatuses
                    error:(NSError **)error {
    return [self enqueueKind:kind path:path headers:headers body:body meta:meta keepResult:keepResult
            acceptedStatuses:acceptedStatuses retryTransient:NO error:error];
}

- (NSString *)enqueueKind:(NSString *)kind
                     path:(NSString *)path
                  headers:(NSDictionary<NSString *, NSString *> *)headers
                     body:(NSData *)body
                     meta:(NSDictionary *)meta
               keepResult:(BOOL)keepResult
         acceptedStatuses:(NSArray<NSNumber *> *)acceptedStatuses
           retryTransient:(BOOL)retryTransient
                    error:(NSError **)error {
    __block NSString *itemID = nil;
    __block NSError *failure = nil;
    dispatch_sync(_queue, ^{
        // Strictly increasing ms stamp, so ids sort oldest-first even for items enqueued in the same millisecond.
        static unsigned long long lastStamp = 0;
        unsigned long long stamp = (unsigned long long)([[NSDate date] timeIntervalSince1970] * 1000);
        if (stamp <= lastStamp) stamp = lastStamp + 1;
        lastStamp = stamp;
        NSString *iid = [NSString stringWithFormat:@"%013llu-%@", stamp, [NSUUID UUID].UUIDString];
        if (![body writeToURL:[self bodyURLForID:iid] options:kWriteOptions error:&failure]) return;
        NSDictionary *item = @{
            @"id": iid, @"kind": kind, @"path": path, @"headers": headers,
            @"state": GLDurableOutboxStatePending, @"keepResult": @(keepResult),
            @"acceptedStatuses": acceptedStatuses ?: @[], @"retryTransient": @(retryTransient), @"meta": meta ?: @{},
            @"createdAt": @([[NSDate date] timeIntervalSince1970]), @"attempts": @0,
        };
        if (![self writeItem:item error:&failure]) {
            [self deleteFilesForID:iid];
            return;
        }
        itemID = iid;
    });
    if (!itemID && error) *error = failure;
    return itemID;
}

- (void)flushWithCompletion:(void (^)(void))completion {
    dispatch_async(_queue, ^{
        if (completion) [self->_waiters addObject:[completion copy]];
        if (self->_running) {
            self->_rerun = YES;
            return;
        }
        self->_running = YES;
        [self sendNext];
    });
}

- (NSArray<NSDictionary *> *)items {
    __block NSArray *result;
    dispatch_sync(_queue, ^{ result = [self loadItems]; });
    return result;
}

- (NSDictionary *)itemWithID:(NSString *)itemID {
    for (NSDictionary *item in [self items]) {
        if ([item[@"id"] isEqualToString:itemID]) return item;
    }
    return nil;
}

- (NSData *)bodyDataForItemID:(NSString *)itemID {
    __block NSData *data;
    dispatch_sync(_queue, ^{ data = [NSData dataWithContentsOfURL:[self bodyURLForID:itemID]]; });
    return data;
}

- (NSData *)resultDataForItemID:(NSString *)itemID {
    __block NSData *data;
    dispatch_sync(_queue, ^{ data = [NSData dataWithContentsOfURL:[self resultURLForID:itemID]]; });
    return data;
}

- (void)removeItemID:(NSString *)itemID {
    dispatch_sync(_queue, ^{ [self deleteFilesForID:itemID]; });
}

- (void)retryRejectedItemID:(NSString *)itemID {
    dispatch_sync(_queue, ^{
        for (NSDictionary *item in [self loadItems]) {
            if (![item[@"id"] isEqualToString:itemID]) continue;
            NSMutableDictionary *m = [item mutableCopy];
            m[@"state"] = GLDurableOutboxStatePending;
            [m removeObjectForKey:@"rejectedStatus"];
            NSError *error = nil;
            if (![self writeItem:m error:&error]) [NSException raise:NSInternalInconsistencyException format:@"GLDurableOutbox: retry write failed: %@", error];
        }
    });
}

#pragma mark - Sending (on _queue)

- (NSMutableURLRequest *)requestForItem:(NSDictionary *)item path:(NSString *)path {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:_urlBuilder(path)];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 60;
    [item[@"headers"] enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        [request setValue:value forHTTPHeaderField:key];
    }];
    [request setValue:[@"Bearer " stringByAppendingString:_token] forHTTPHeaderField:@"Authorization"];
    // Same key on every replay of this item: the box dedupes /drop on it, so a retry after an unknown outcome files nothing twice.
    [request setValue:item[@"id"] forHTTPHeaderField:@"X-Idempotency-Key"];
    return request;
}

/// Transport error or transient HTTP: the item stays pending, attempts +1, and it goes behind other items.
- (void)recordFailureForItem:(NSDictionary *)item reason:(NSString *)reason {
    NSMutableDictionary *m = [item mutableCopy];
    NSError *writeError = nil;
    m[@"attempts"] = @([item[@"attempts"] integerValue] + 1);
    m[@"lastError"] = reason;
    m[@"lastAttemptAt"] = @([[NSDate date] timeIntervalSince1970]);
    GLLog(@"%@ %@ transport error, kept: %@", item[@"kind"], item[@"id"], reason);
    if (![self writeItem:m error:&writeError]) GLLog(@"attempt-count write failed: %@", writeError);
    [self finishPass];
}

/// Sends the next 1 MB piece of a large /drop body, starting at the item's persisted uploadedOffset.
- (void)sendChunkOfItem:(NSDictionary *)item {
    NSString *itemID = item[@"id"];
    NSError *readError = nil;
    NSData *whole = [NSData dataWithContentsOfURL:[self bodyURLForID:itemID] options:NSDataReadingMappedIfSafe error:&readError];
    if (!whole) {
        [self recordFailureForItem:item reason:[NSString stringWithFormat:@"cannot read body: %@", readError]];
        return;
    }
    unsigned long long total = whole.length;
    unsigned long long offset = [item[@"uploadedOffset"] unsignedLongLongValue];
    if (offset > total) offset = 0;
    unsigned long long length = MIN(kGLDurableChunkSize, total - offset);
    NSURL *chunkURL = [self chunkURLForID:itemID];
    NSData *piece = [whole subdataWithRange:NSMakeRange((NSUInteger)offset, (NSUInteger)length)];
    NSError *writeError = nil;
    if (![piece writeToURL:chunkURL options:kWriteOptions error:&writeError]) {
        [self recordFailureForItem:item reason:[NSString stringWithFormat:@"cannot write chunk: %@", writeError]];
        return;
    }
    NSMutableURLRequest *request = [self requestForItem:item path:@"/drop/chunk"];
    [request setValue:itemID forHTTPHeaderField:@"X-Upload-Id"];
    [request setValue:[NSString stringWithFormat:@"%llu", offset] forHTTPHeaderField:@"X-Upload-Offset"];
    [request setValue:[NSString stringWithFormat:@"%llu", total] forHTTPHeaderField:@"X-Upload-Total"];
    NSURLSessionUploadTask *task = [_session uploadTaskWithRequest:request
                                                          fromFile:chunkURL
                                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(self->_queue, ^{
            [[NSFileManager defaultManager] removeItemAtURL:chunkURL error:NULL];
            [self handleChunkOfItem:item offset:offset total:total data:data response:response error:error];
        });
    }];
    [task resume];
}

- (void)handleChunkOfItem:(NSDictionary *)item offset:(unsigned long long)offset total:(unsigned long long)total
                     data:(NSData *)data response:(NSURLResponse *)response error:(NSError *)error {
    if (error) {
        [self recordFailureForItem:item reason:error.localizedDescription];
        return;
    }
    NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
    if (status >= 500 || status == 429 || status == 408) {
        [self recordFailureForItem:item reason:[NSString stringWithFormat:@"HTTP %ld", (long)status]];
        return;
    }
    BOOL ok = status >= 200 && status < 300;
    if (!ok && status != 409) {
        [self handleItem:item data:data response:response error:nil];   // rejects like any other 4xx
        return;
    }
    id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    NSDictionary *info = [json isKindOfClass:[NSDictionary class]] ? json : nil;
    if (ok && [info[@"complete"] boolValue]) {
        [self handleItem:item data:data response:response error:nil];   // same finish as a 2xx on the whole-file path
        return;
    }
    if (![info[@"received"] isKindOfClass:[NSNumber class]]) {
        [self recordFailureForItem:item reason:[NSString stringWithFormat:@"chunk reply without received (HTTP %ld)", (long)status]];
        return;
    }
    unsigned long long next = [info[@"received"] unsignedLongLongValue];
    // 409 may move the offset either way (resync); a 200 must move it forward. Anything else would loop forever.
    if (next == offset || next > total || (ok && next < offset)) {
        [self recordFailureForItem:item reason:[NSString stringWithFormat:@"chunk reply no progress: received %llu at offset %llu of %llu", next, offset, total]];
        return;
    }
    NSMutableDictionary *m = [item mutableCopy];
    m[@"uploadedOffset"] = @(next);
    NSError *writeError = nil;
    if (![self writeItem:m error:&writeError]) GLLog(@"uploadedOffset write failed: %@", writeError);
    [self sendChunkOfItem:m];
}

- (void)sendNext {
    NSDictionary *item = [self oldestPendingItem];
    if (!item) {
        [self finishPass];
        return;
    }
    if ([item[@"path"] isEqualToString:@"/drop"]) {
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:[self bodyURLForID:item[@"id"]].path error:NULL];
        if ([attrs[NSFileSize] unsignedLongLongValue] > kGLDurableChunkThreshold) {
            [self sendChunkOfItem:item];
            return;
        }
    }
    NSMutableURLRequest *request = [self requestForItem:item path:item[@"path"]];
    NSURLSessionUploadTask *task = [_session uploadTaskWithRequest:request
                                                          fromFile:[self bodyURLForID:item[@"id"]]
                                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(self->_queue, ^{ [self handleItem:item data:data response:response error:error]; });
    }];
    [task resume];
}

- (void)handleItem:(NSDictionary *)item data:(NSData *)data response:(NSURLResponse *)response error:(NSError *)error {
    NSMutableDictionary *m = [item mutableCopy];
    NSError *writeError = nil;
    NSInteger httpStatus = error ? 0 : ((NSHTTPURLResponse *)response).statusCode;
    BOOL transientHTTP = !error && [item[@"retryTransient"] boolValue] && (httpStatus >= 500 || httpStatus == 429 || httpStatus == 408)
        && ![item[@"acceptedStatuses"] containsObject:@(httpStatus)];
    if (error || transientHTTP) {
        [self recordFailureForItem:item reason:error ? error.localizedDescription : [NSString stringWithFormat:@"HTTP %ld", (long)httpStatus]];
        return;
    }
    NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
    BOOL accepted = (status >= 200 && status < 300) || [item[@"acceptedStatuses"] containsObject:@(status)];
    if (accepted) {
        if ([item[@"keepResult"] boolValue]) {
            if (![(data ?: [NSData data]) writeToURL:[self resultURLForID:item[@"id"]] options:kWriteOptions error:&writeError]) {
                [NSException raise:NSInternalInconsistencyException format:@"GLDurableOutbox: result write failed: %@", writeError];
            }
            m[@"state"] = GLDurableOutboxStateCompleted;
            m[@"resultStatus"] = @(status);
            if (![self writeItem:m error:&writeError]) [NSException raise:NSInternalInconsistencyException format:@"GLDurableOutbox: manifest write failed: %@", writeError];
        } else {
            [self deleteFilesForID:item[@"id"]];
        }
    } else {
        NSString *snippet = [[NSString alloc] initWithData:data ?: [NSData data] encoding:NSUTF8StringEncoding] ?: @"";
        if (snippet.length > 200) snippet = [snippet substringToIndex:200];
        m[@"state"] = GLDurableOutboxStateRejected;
        m[@"rejectedStatus"] = @(status);
        m[@"lastError"] = [NSString stringWithFormat:@"HTTP %ld %@", (long)status, snippet];
        if (![self writeItem:m error:&writeError]) [NSException raise:NSInternalInconsistencyException format:@"GLDurableOutbox: manifest write failed: %@", writeError];
        GLLog(@"%@ %@ rejected: %@", item[@"kind"], item[@"id"], m[@"lastError"]);
        [self postOnMain:GLDurableOutboxDidRejectNotification item:m];
    }
    [self sendNext];
}

- (void)postOnMain:(NSString *)name item:(NSDictionary *)item {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:name object:self userInfo:@{@"item": item}];
    });
}

- (void)finishPass {
    if (_rerun) {
        _rerun = NO;
        [self sendNext];
        return;
    }
    _running = NO;
    NSArray *waiters = [_waiters copy];
    [_waiters removeAllObjects];
    dispatch_async(dispatch_get_main_queue(), ^{
        for (void (^waiter)(void) in waiters) waiter();
    });
    if ([self oldestPendingItem] && !_retryScheduled) {
        _retryScheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_retryInterval * NSEC_PER_SEC)), _queue, ^{
            self->_retryScheduled = NO;
            if (self->_running) return;
            self->_running = YES;
            [self sendNext];
        });
    }
}

@end
