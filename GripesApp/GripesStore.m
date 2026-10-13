#import "GripesStore.h"

@interface GripesStore ()
@property (nonatomic, strong) NSURL *entriesURL;
@property (nonatomic, strong) NSURL *outboxURL;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *entries; // id -> entry
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *dirty;       // id -> updatedAt at mark time
@property (nonatomic, copy) NSString *lastPull;                                         // ISO time of the last pull start
@property (nonatomic, assign) BOOL syncing;
@end

@implementation GripesStore

- (instancetype)initWithDirectory:(NSURL *)directory {
    if ((self = [super init])) {
        _entriesURL = [directory URLByAppendingPathComponent:@"gripes-entries.json"];
        _outboxURL = [directory URLByAppendingPathComponent:@"gripes-outbox.json"];
        _entries = [NSMutableDictionary dictionary];
        _dirty = [NSMutableDictionary dictionary];
        NSData *data = [NSData dataWithContentsOfURL:_entriesURL];
        if (data) {
            NSError *error = nil;
            NSArray *list = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
            // A corrupt store must be loud: silently starting empty would then overwrite the file.
            NSAssert([list isKindOfClass:NSArray.class], @"gripes-entries.json unreadable: %@", error);
            for (NSDictionary *e in list) _entries[e[@"id"]] = e;
        }
        data = [NSData dataWithContentsOfURL:_outboxURL];
        if (data) {
            NSError *error = nil;
            NSDictionary *box = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
            NSAssert([box isKindOfClass:NSDictionary.class], @"gripes-outbox.json unreadable: %@", error);
            [_dirty addEntriesFromDictionary:box[@"dirty"]];
            _lastPull = [box[@"lastPull"] isKindOfClass:NSString.class] ? box[@"lastPull"] : nil;
        }
    }
    return self;
}

+ (NSDate *)dateFromISO:(NSString *)iso {
    static NSISO8601DateFormatter *frac, *plain;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        frac = [[NSISO8601DateFormatter alloc] init];
        frac.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        plain = [[NSISO8601DateFormatter alloc] init];
    });
    return [frac dateFromString:iso] ?: [plain dateFromString:iso];
}

// Caller holds @synchronized(self).
- (BOOL)persist:(NSError **)error {
    NSData *entries = [NSJSONSerialization dataWithJSONObject:self.entries.allValues options:0 error:error];
    if (!entries || ![entries writeToURL:self.entriesURL options:NSDataWritingAtomic error:error]) return NO;
    return [self persistOutbox:error];
}

- (BOOL)persistOutbox:(NSError **)error {
    NSDictionary *box = @{@"dirty": self.dirty, @"lastPull": self.lastPull ?: NSNull.null};
    NSData *data = [NSJSONSerialization dataWithJSONObject:box options:0 error:error];
    return data && [data writeToURL:self.outboxURL options:NSDataWritingAtomic error:error];
}

- (NSArray<NSDictionary *> *)allEntries {
    @synchronized (self) { return [self.entries.allValues copy]; }
}

- (NSArray<NSString *> *)dirtyIDs {
    @synchronized (self) { return self.dirty.allKeys; }
}

- (BOOL)upsertEntry:(NSDictionary *)entry error:(NSError **)error {
    @synchronized (self) {
        NSString *ident = entry[@"id"];
        NSDictionary *old = self.entries[ident];
        if (old) {
            NSDate *a = [GripesStore dateFromISO:old[@"updatedAt"]], *b = [GripesStore dateFromISO:entry[@"updatedAt"]];
            if (a && b && [a compare:b] == NSOrderedDescending) return YES; // the stored one is newer
        }
        self.entries[ident] = entry;
        self.dirty[ident] = entry[@"updatedAt"];
        return [self persist:error];
    }
}

- (BOOL)deleteEntryWithID:(NSString *)ident error:(NSError **)error {
    @synchronized (self) {
        [self.entries removeObjectForKey:ident];
        [self.dirty removeObjectForKey:ident];
        return [self persist:error];
    }
}

+ (NSMutableURLRequest *)requestWithURL:(NSURL *)url token:(NSString *)token body:(NSDictionary *)body {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 20;
    [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    if (body) {
        req.HTTPMethod = @"POST";
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    }
    return req;
}

- (void)syncWithBaseURL:(NSURL *)baseURL token:(NSString *)token session:(NSURLSession *)session completion:(void (^)(BOOL))completion {
    void (^finish)(BOOL) = ^(BOOL changed) {
        @synchronized (self) { self.syncing = NO; }
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(changed); });
    };
    NSMutableArray *batch = [NSMutableArray array];
    NSDictionary *sent;
    @synchronized (self) {
        if (self.syncing) { dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(NO); }); return; }
        self.syncing = YES;
        sent = [self.dirty copy];
        for (NSString *ident in sent) if (self.entries[ident]) [batch addObject:self.entries[ident]];
    }
    void (^pull)(void) = ^{
        NSString *since;
        @synchronized (self) { since = self.lastPull; }
        NSString *started = [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]];
        NSURLComponents *c = [NSURLComponents componentsWithURL:[baseURL URLByAppendingPathComponent:@"api/entries"] resolvingAgainstBaseURL:NO];
        if (since) c.queryItems = @[[NSURLQueryItem queryItemWithName:@"since" value:since]];
        [[session dataTaskWithRequest:[GripesStore requestWithURL:c.URL token:token body:nil]
                    completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
            NSInteger status = ((NSHTTPURLResponse *)resp).statusCode;
            if (error || status / 100 != 2) {
                NSLog(@"[Gripes] pull failed: status=%ld error=%@", (long)status, error);
                finish(NO);
                return;
            }
            NSDictionary *body = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            if (![body[@"entries"] isKindOfClass:NSArray.class]) {
                NSLog(@"[Gripes] pull returned an unexpected body: %@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
                finish(NO);
                return;
            }
            BOOL changed = NO;
            @synchronized (self) {
                for (NSDictionary *incoming in body[@"entries"]) {
                    NSDictionary *mine = self.entries[incoming[@"id"]];
                    NSDate *theirs = [GripesStore dateFromISO:incoming[@"updatedAt"]];
                    NSDate *ours = mine ? [GripesStore dateFromISO:mine[@"updatedAt"]] : nil;
                    if (!theirs || (ours && [theirs compare:ours] != NSOrderedDescending)) continue;
                    self.entries[incoming[@"id"]] = incoming;
                    [self.dirty removeObjectForKey:incoming[@"id"]]; // the server copy is newer than anything we still owed it
                    changed = YES;
                }
                self.lastPull = started;
                NSError *werr = nil;
                if (![self persist:&werr]) NSLog(@"[Gripes] could not persist pulled entries: %@", werr);
            }
            finish(changed);
        }] resume];
    };
    if (batch.count == 0) { pull(); return; }
    NSURLRequest *req = [GripesStore requestWithURL:[baseURL URLByAppendingPathComponent:@"api/entries"] token:token body:@{@"entries": batch}];
    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSInteger status = ((NSHTTPURLResponse *)resp).statusCode;
        if (error || status / 100 != 2) {
            // Stays dirty and is retried on the next launch/foreground; the UI never sees this.
            NSLog(@"[Gripes] push failed: status=%ld error=%@ body=%@", (long)status, error, data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"");
            finish(NO);
            return;
        }
        @synchronized (self) {
            // Only clear entries not re-edited while the request was in flight.
            for (NSString *ident in sent) if ([self.dirty[ident] isEqualToString:sent[ident]]) [self.dirty removeObjectForKey:ident];
            NSError *werr = nil;
            if (![self persistOutbox:&werr]) NSLog(@"[Gripes] could not persist outbox: %@", werr);
        }
        pull();
    }] resume];
}

@end
