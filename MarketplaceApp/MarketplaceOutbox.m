#import "MarketplaceOutbox.h"

@implementation MarketplaceOutbox {
    NSURL *_fileURL;
    NSMutableArray<NSDictionary *> *_items;
    BOOL _flushing;
    NSMutableArray<void (^)(void)> *_waiters;
}

- (instancetype)initWithFileURL:(NSURL *)fileURL {
    self = [super init];
    if (!self) return nil;
    _fileURL = fileURL;
    _items = [NSMutableArray array];
    _waiters = [NSMutableArray array];
    NSData *data = [NSData dataWithContentsOfURL:fileURL];
    if (data) {
        NSError *error = nil;
        NSArray *stored = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        // A corrupt outbox must be loud: silently starting empty would drop replies Oliver believes were sent.
        if (![stored isKindOfClass:NSArray.class]) {
            [NSException raise:@"MarketplaceOutboxCorrupt" format:@"%@: %@", fileURL.path, error];
        }
        [_items addObjectsFromArray:stored];
    }
    return self;
}

+ (NSDictionary *)replyBodyForListing:(NSString *)listing buyer:(NSString *)buyer text:(NSString *)text opId:(NSString *)opId {
    return @{
        @"category": @"FB_REPLY",
        @"data": @{@"listing": listing, @"buyer": buyer},
        @"text": text,
        @"opId": opId,
    };
}

+ (NSMutableURLRequest *)requestWithBaseURL:(NSURL *)baseURL path:(NSString *)path token:(NSString *)token body:(NSDictionary *)body {
    NSURL *url = [NSURL URLWithString:[baseURL.absoluteString stringByAppendingString:path]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    return req;
}

- (BOOL)persist:(NSError **)error {
    NSData *data = [NSJSONSerialization dataWithJSONObject:_items options:0 error:error];
    if (!data) return NO;
    return [data writeToURL:_fileURL options:NSDataWritingAtomic error:error];
}

- (NSDictionary *)enqueueReplyForListing:(NSString *)listing buyer:(NSString *)buyer text:(NSString *)text error:(NSError **)error {
    NSString *opId = NSUUID.UUID.UUIDString;
    NSDictionary *item = @{
        @"id": opId,
        @"listing": listing,
        @"buyer": buyer,
        @"text": text,
        @"status": @"pending",
        @"createdAt": @([NSDate.date timeIntervalSince1970]),
    };
    @synchronized (self) {
        [_items addObject:item];
        if (![self persist:error]) {
            [_items removeLastObject];
            return nil;
        }
    }
    return item;
}

- (NSArray<NSDictionary *> *)allItems {
    @synchronized (self) { return [_items copy]; }
}

- (NSArray<NSDictionary *> *)pendingItems {
    return [[self allItems] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"status == 'pending'"]];
}

- (NSDictionary *)itemWithID:(NSString *)itemID {
    for (NSDictionary *item in [self allItems]) if ([item[@"id"] isEqualToString:itemID]) return item;
    return nil;
}

- (void)removeItemWithID:(NSString *)itemID {
    @synchronized (self) {
        NSDictionary *item = [self itemWithID:itemID];
        if (!item) return;
        [_items removeObject:item];
        NSError *error = nil;
        if (![self persist:&error]) NSLog(@"[Marketplace] outbox write failed: %@", error);
    }
}

- (void)markRejectedItemWithID:(NSString *)itemID error:(NSString *)message {
    @synchronized (self) {
        NSDictionary *item = [self itemWithID:itemID];
        if (!item) return;
        NSMutableDictionary *updated = [item mutableCopy];
        updated[@"status"] = @"rejected";
        updated[@"lastError"] = message;
        _items[[_items indexOfObject:item]] = updated;
        NSError *error = nil;
        if (![self persist:&error]) NSLog(@"[Marketplace] outbox write failed: %@", error);
    }
}

- (void)flushWithBaseURL:(NSURL *)baseURL
                   token:(NSString *)token
                 session:(NSURLSession *)session
                rejected:(void (^)(NSDictionary *))rejected
              completion:(void (^)(void))completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) [self->_waiters addObject:completion];
        if (self->_flushing) return;
        self->_flushing = YES;
        [self sendNext:[self pendingItems] index:0 baseURL:baseURL token:token session:session rejected:rejected];
    });
}

- (void)finishFlush {
    _flushing = NO;
    NSArray *waiters = [_waiters copy];
    [_waiters removeAllObjects];
    for (void (^w)(void) in waiters) w();
}

- (void)sendNext:(NSArray<NSDictionary *> *)items index:(NSUInteger)i baseURL:(NSURL *)baseURL token:(NSString *)token
         session:(NSURLSession *)session rejected:(void (^)(NSDictionary *))rejected {
    if (i >= items.count) { [self finishFlush]; return; }
    NSDictionary *item = items[i];
    NSDictionary *body = [MarketplaceOutbox replyBodyForListing:item[@"listing"] buyer:item[@"buyer"] text:item[@"text"] opId:item[@"id"]];
    NSURLRequest *req = [MarketplaceOutbox requestWithBaseURL:baseURL path:@"/reply" token:token body:body];
    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                // Outcome unknown (server may have seen it): keep queued, opId makes the retry idempotent.
                NSLog(@"[Marketplace] reply %@ kept for retry: %@", item[@"id"], error);
                [self finishFlush];
                return;
            }
            NSInteger status = ((NSHTTPURLResponse *)resp).statusCode;
            if (status >= 200 && status < 300) {
                [self removeItemWithID:item[@"id"]];
            } else {
                NSString *text = [[NSString alloc] initWithData:data ?: NSData.data encoding:NSUTF8StringEncoding];
                [self markRejectedItemWithID:item[@"id"] error:[NSString stringWithFormat:@"HTTP %ld %@", (long)status, text ?: @""]];
                if (rejected) rejected([self itemWithID:item[@"id"]]);
            }
            [self sendNext:items index:i + 1 baseURL:baseURL token:token session:session rejected:rejected];
        });
    }] resume];
}

@end
