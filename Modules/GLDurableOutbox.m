#import "GLDurableOutbox.h"

#import "GLLog.h"

NSString *const GLDurableOutboxDidRejectNotification = @"GLDurableOutboxDidReject";
NSString *const GLDurableOutboxDidCompleteNotification = @"GLDurableOutboxDidComplete";
NSString *const GLDurableOutboxStatePending = @"pending";
NSString *const GLDurableOutboxStateRejected = @"rejected";
NSString *const GLDurableOutboxStateCompleted = @"completed";

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

- (BOOL)writeItem:(NSDictionary *)item error:(NSError **)error {
    NSData *json = [NSJSONSerialization dataWithJSONObject:item options:0 error:error];
    if (!json) return NO;
    return [json writeToURL:[self manifestURLForID:item[@"id"]] options:kWriteOptions error:error];
}

- (void)deleteFilesForID:(NSString *)itemID {
    for (NSURL *url in @[[self manifestURLForID:itemID], [self bodyURLForID:itemID], [self resultURLForID:itemID]]) {
        [[NSFileManager defaultManager] removeItemAtURL:url error:NULL];
    }
}

/// Oldest first: ids start with a zero-padded millisecond timestamp.
- (NSArray<NSDictionary *> *)loadItems {
    NSArray<NSString *> *names = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:_directory.path error:NULL]
        sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *name in names) {
        if (![name hasSuffix:@".json"]) continue;
        NSData *data = [NSData dataWithContentsOfURL:[_directory URLByAppendingPathComponent:name]];
        NSDictionary *item = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if (![item isKindOfClass:[NSDictionary class]]) {
            GLLog(@"unreadable manifest %@ left on disk", name);
            continue;
        }
        [items addObject:item];
    }
    return items;
}

- (nullable NSDictionary *)oldestPendingItem {
    for (NSDictionary *item in [self loadItems]) {
        if ([item[@"state"] isEqualToString:GLDurableOutboxStatePending]) return item;
    }
    return nil;
}

#pragma mark - Public

- (NSString *)enqueueKind:(NSString *)kind
                     path:(NSString *)path
                  headers:(NSDictionary<NSString *, NSString *> *)headers
                     body:(NSData *)body
                     meta:(NSDictionary *)meta
               keepResult:(BOOL)keepResult
         acceptedStatuses:(NSArray<NSNumber *> *)acceptedStatuses
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
            @"acceptedStatuses": acceptedStatuses ?: @[], @"meta": meta ?: @{},
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

- (void)sendNext {
    NSDictionary *item = [self oldestPendingItem];
    if (!item) {
        [self finishPass];
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:_urlBuilder(item[@"path"])];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 60;
    [item[@"headers"] enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        [request setValue:value forHTTPHeaderField:key];
    }];
    [request setValue:[@"Bearer " stringByAppendingString:_token] forHTTPHeaderField:@"Authorization"];
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
    if (error) {
        m[@"attempts"] = @([item[@"attempts"] integerValue] + 1);
        m[@"lastError"] = error.localizedDescription;
        GLLog(@"%@ %@ transport error, kept: %@", item[@"kind"], item[@"id"], error.localizedDescription);
        if (![self writeItem:m error:&writeError]) GLLog(@"attempt-count write failed: %@", writeError);
        [self finishPass];
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
            [self postOnMain:GLDurableOutboxDidCompleteNotification item:m];
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
