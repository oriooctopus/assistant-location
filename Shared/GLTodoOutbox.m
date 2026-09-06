#import "GLTodoOutbox.h"

#import "BakedConfig.h"
#import "GLLog.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - GLTodoOutboxOp

@implementation GLTodoOutboxOp

- (instancetype)initWithOpId:(NSString *)opId path:(NSString *)path body:(NSDictionary<NSString *, id> *)body {
    self = [super init];
    if (self) {
        _opId = [opId copy];
        _path = [path copy];
        _body = [body copy];
    }
    return self;
}

+ (nullable instancetype)opFromDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) return nil;
    NSString *opId = dictionary[@"opId"];
    NSString *path = dictionary[@"path"];
    NSDictionary *body = dictionary[@"body"];
    if (![opId isKindOfClass:[NSString class]] || opId.length == 0) return nil;
    if (![path isKindOfClass:[NSString class]] || path.length == 0) return nil;
    if (![body isKindOfClass:[NSDictionary class]]) return nil;
    return [[self alloc] initWithOpId:opId path:path body:body];
}

- (NSDictionary<NSString *, id> *)toDictionary {
    return @{@"opId": self.opId, @"path": self.path, @"body": self.body};
}

- (id)copyWithZone:(nullable NSZone *)zone {
    // Immutable value object -- no need for a real copy.
    return self;
}

- (BOOL)isEqual:(id)other {
    if (self == other) return YES;
    if (![other isKindOfClass:[GLTodoOutboxOp class]]) return NO;
    GLTodoOutboxOp *o = other;
    return [self.opId isEqualToString:o.opId] && [self.path isEqualToString:o.path] && [self.body isEqualToDictionary:o.body];
}

- (NSUInteger)hash {
    return self.opId.hash;
}

@end

#pragma mark - GLTodoOutboxState

@implementation GLTodoOutboxState

- (instancetype)initWithRemaining:(NSArray<GLTodoOutboxOp *> *)remaining
                             sent:(NSArray<GLTodoOutboxOp *> *)sent
                           failed:(nullable NSDictionary<NSString *, id> *)failed {
    self = [super init];
    if (self) {
        _remaining = [remaining copy];
        _sent = [sent copy];
        _failed = [failed copy];
    }
    return self;
}

+ (instancetype)emptyState {
    return [[self alloc] initWithRemaining:@[] sent:@[] failed:nil];
}

- (id)copyWithZone:(nullable NSZone *)zone {
    return self;
}

- (nullable GLTodoOutboxOp *)nextOpToSend {
    // A recorded failure halts the chain in place -- this class never skips
    // or retries a failed op itself (see GLTodoOutbox.h's header comment).
    if (self.failed != nil) return nil;
    return self.remaining.firstObject;
}

- (GLTodoOutboxState *)stateByApplyingOutcome:(GLTodoOutboxOutcome)outcome status:(NSInteger)status {
    NSParameterAssert(self.remaining.count > 0);
    if (self.remaining.count == 0) return self;
    GLTodoOutboxOp *head = self.remaining.firstObject;

    if (outcome == GLTodoOutboxOutcomeSuccess) {
        NSArray<GLTodoOutboxOp *> *newRemaining = self.remaining.count > 1
            ? [self.remaining subarrayWithRange:NSMakeRange(1, self.remaining.count - 1)]
            : @[];
        NSArray<GLTodoOutboxOp *> *newSent = [self.sent arrayByAddingObject:head];
        return [[GLTodoOutboxState alloc] initWithRemaining:newRemaining sent:newSent failed:nil];
    }

    // Every other outcome (transport error, HTTP error, or a 2xx whose body
    // isn't the shape the server actually returns) halts the chain with
    // `remaining` UNTOUCHED -- the failed op stays at the head, never
    // skipped, never retried by this class. The web side owns conflict
    // arbitration for the failure and will re-send it itself once it
    // reclaims the outbox.
    return [[GLTodoOutboxState alloc] initWithRemaining:self.remaining
                                                    sent:self.sent
                                                  failed:@{@"opId": head.opId, @"status": @(status)}];
}

@end

#pragma mark - GLTodoOutbox

// Same host, same "build it off GL_BAKED_HOST, let an unbaked host fail
// through NSURLSession's ordinary error path" convention as
// GLWebBridge.m's kGLWebBridgeThemeServerPort / GLWebBridgeThemeServerURL --
// this is todo-sorter's own port (see Modules/Todos/TodosViewController.m).
static NSInteger const kGLTodoOutboxServerPort = 8308;

static NSString *const kGLTodoOutboxBackgroundSessionIdentifier = @"com.gl.todo.outbox";

@interface GLTodoOutbox ()
@property(nonatomic, strong, readonly) NSObject *lock;
@property(nonatomic, copy, readonly) NSURL *storeURL;
@property(nonatomic, copy, readonly) NSString *serverBase;
@property(nonatomic, strong, readonly) NSURLSession *session;

// State for whatever task is currently in flight -- there is never more
// than one (see the class's header comment on strict sequencing). `nil`
// activeTask means idle: nothing in flight, either because the queue is
// empty, halted on a failure, or between "success persisted" and "next
// upload started" (a window entirely inside a single @synchronized block,
// so never observable from outside).
@property(nonatomic, strong, nullable) NSURLSessionUploadTask *activeTask;
@property(nonatomic, strong, nullable) NSMutableData *activeResponseData;
@property(nonatomic, assign) NSInteger activeResponseStatus;
@property(nonatomic, copy, nullable) NSURL *activeTempFileURL;

@end

@implementation GLTodoOutbox

+ (NSString *)backgroundSessionIdentifier {
    return kGLTodoOutboxBackgroundSessionIdentifier;
}

+ (NSURL *)defaultStoreURL {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *appSupport = [[fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
    NSURL *dir = [appSupport URLByAppendingPathComponent:@"GLTodoOutbox" isDirectory:YES];
    return [dir URLByAppendingPathComponent:@"outbox.json" isDirectory:NO];
}

+ (instancetype)sharedOutbox {
    static GLTodoOutbox *outbox;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *serverBase = [NSString stringWithFormat:@"http://%@:%ld", GL_BAKED_HOST, (long)kGLTodoOutboxServerPort];
        outbox = [[GLTodoOutbox alloc] initWithStoreURL:[self defaultStoreURL] serverBase:serverBase sessionConfiguration:nil];
    });
    return outbox;
}

- (instancetype)initWithStoreURL:(NSURL *)storeURL
                       serverBase:(NSString *)serverBase
              sessionConfiguration:(nullable NSURLSessionConfiguration *)configuration {
    self = [super init];
    if (self) {
        _lock = [NSObject new];
        _storeURL = [storeURL copy];
        _serverBase = [serverBase copy];

        // The real production path (configuration == nil) is a background
        // session so iOS can finish/retry this upload chain even while the
        // app is suspended or has been killed and relaunched for exactly
        // this purpose. Built internally (never handed in already-made)
        // because its delegate has to be `self`, which doesn't exist until
        // this initializer runs. delegateQueue is serial
        // (maxConcurrentOperationCount = 1) -- belt-and-suspenders alongside
        // our own @synchronized gating, not a substitute for it: the gating
        // is what actually decides whether a second task gets CREATED, this
        // only decides the order delegate callbacks for a single task are
        // delivered in.
        NSURLSessionConfiguration *config = configuration ?:
            [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:[GLTodoOutbox backgroundSessionIdentifier]];
        NSOperationQueue *queue = [NSOperationQueue new];
        queue.maxConcurrentOperationCount = 1;
        _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:queue];
    }
    return self;
}

#pragma mark - Persistence

- (NSDictionary<NSString *, id> *)dictionaryFromState:(GLTodoOutboxState *)state {
    NSMutableArray<NSDictionary *> *remaining = [NSMutableArray arrayWithCapacity:state.remaining.count];
    for (GLTodoOutboxOp *op in state.remaining) [remaining addObject:[op toDictionary]];
    NSMutableArray<NSDictionary *> *sent = [NSMutableArray arrayWithCapacity:state.sent.count];
    for (GLTodoOutboxOp *op in state.sent) [sent addObject:[op toDictionary]];
    return @{
        @"remaining": remaining,
        @"sent": sent,
        @"failed": state.failed ?: [NSNull null],
    };
}

// Never returns nil -- a missing file (fresh install, or right after a
// reclaim persisted the empty state) is the normal idle state, not an
// error. A file that exists but fails to parse as the expected shape is a
// genuine bug (this class is the only writer, and always writes atomically)
// but the only sane recovery from a boundary condition like disk
// corruption is still to start over from empty, so this logs loudly and
// does that rather than crashing the app on launch.
- (GLTodoOutboxState *)stateFromDisk {
    NSData *data = [NSData dataWithContentsOfURL:self.storeURL];
    if (data == nil) return [GLTodoOutboxState emptyState];

    NSError *error = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![parsed isKindOfClass:[NSDictionary class]]) {
        GLLog(@"outbox store at %@ failed to parse, starting from empty: %@", self.storeURL, error);
        return [GLTodoOutboxState emptyState];
    }
    NSDictionary *dict = parsed;

    NSArray<GLTodoOutboxOp *> *remaining = [self opsFromArray:dict[@"remaining"]];
    NSArray<GLTodoOutboxOp *> *sent = [self opsFromArray:dict[@"sent"]];
    id failedValue = dict[@"failed"];
    NSDictionary *failed = [failedValue isKindOfClass:[NSDictionary class]] ? failedValue : nil;

    return [[GLTodoOutboxState alloc] initWithRemaining:remaining sent:sent failed:failed];
}

- (NSArray<GLTodoOutboxOp *> *)opsFromArray:(id)maybeArray {
    if (![maybeArray isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray<GLTodoOutboxOp *> *ops = [NSMutableArray arrayWithCapacity:[(NSArray *)maybeArray count]];
    for (id entry in (NSArray *)maybeArray) {
        GLTodoOutboxOp *op = [GLTodoOutboxOp opFromDictionary:entry];
        if (op != nil) {
            [ops addObject:op];
        } else {
            GLLog(@"dropped malformed outbox entry on load: %@", entry);
        }
    }
    return ops;
}

- (void)persistState:(GLTodoOutboxState *)state {
    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:[self dictionaryFromState:state] options:0 error:&jsonError];
    if (jsonError || data == nil) {
        GLLog(@"failed to serialize outbox state: %@", jsonError);
        return;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtURL:[self.storeURL URLByDeletingLastPathComponent]
 withIntermediateDirectories:YES
                  attributes:nil
                       error:nil];
    NSError *writeError = nil;
    if (![data writeToURL:self.storeURL options:NSDataWritingAtomic error:&writeError]) {
        GLLog(@"failed to write outbox state to %@: %@", self.storeURL, writeError);
    }
}

- (GLTodoOutboxState *)loadState {
    @synchronized(self.lock) {
        return [self stateFromDisk];
    }
}

#pragma mark - Handoff / reclaim (bridge entry points)

- (NSInteger)handoffWithOps:(NSArray<GLTodoOutboxOp *> *)ops {
    @synchronized(self.lock) {
        GLTodoOutboxState *current = [self stateFromDisk];

        // Idempotency guard: iOS can fire `hidden` and `pagehide` for the
        // same visibility change, and the web page sends an outboxHandoff
        // from each. By the time the second call arrives, the first has
        // already run synchronously to completion (REPLACE + persist +
        // possibly started a task) -- so if the incoming ops are, in
        // order, exactly what's already on disk in `remaining`, this call
        // changes nothing observable and must not re-persist or restart
        // the chain (that would risk a second concurrent upload of the
        // same head op). A REAL new handoff (different ops, or the same
        // ops after real progress was made) always proceeds -- the server
        // is idempotent per-opId regardless, so there is no correctness
        // risk in the rarer case where progress raced ahead of the second
        // call; this guard exists for the ordinary, expected race, not to
        // solve every possible interleaving.
        NSArray<NSString *> *incomingIds = [ops valueForKey:@"opId"];
        NSArray<NSString *> *currentIds = [current.remaining valueForKey:@"opId"];
        if ([incomingIds isEqualToArray:currentIds]) {
            return (NSInteger)ops.count;
        }

        GLTodoOutboxState *newState = [[GLTodoOutboxState alloc] initWithRemaining:ops sent:@[] failed:nil];
        [self persistState:newState];
        [self startNextUploadIfNeeded];
        return (NSInteger)ops.count;
    }
}

- (NSDictionary<NSString *, id> *)reclaim {
    @synchronized(self.lock) {
        if (self.activeTask != nil) {
            [self.activeTask cancel];
            self.activeTask = nil;
            self.activeResponseData = nil;
            self.activeResponseStatus = 0;
            if (self.activeTempFileURL != nil) {
                [[NSFileManager defaultManager] removeItemAtURL:self.activeTempFileURL error:nil];
                self.activeTempFileURL = nil;
            }
        }

        GLTodoOutboxState *current = [self stateFromDisk];
        // Cleared BEFORE returning: a completion callback for the task just
        // cancelled above (or, in principle, any other stale callback) is
        // guarded by the `task != self.activeTask` identity check in
        // -URLSession:task:didCompleteWithError: below, and activeTask is
        // already nil by the time this method returns -- so a callback that
        // fires after this can never resurrect state or write a stale file.
        [self persistState:[GLTodoOutboxState emptyState]];

        NSMutableArray<NSString *> *sentIds = [NSMutableArray arrayWithCapacity:current.sent.count];
        for (GLTodoOutboxOp *op in current.sent) [sentIds addObject:op.opId];
        NSMutableArray<NSDictionary *> *remainingDicts = [NSMutableArray arrayWithCapacity:current.remaining.count];
        for (GLTodoOutboxOp *op in current.remaining) [remainingDicts addObject:[op toDictionary]];

        return @{
            @"sent": sentIds,
            @"remaining": remainingDicts,
            @"failed": current.failed ?: [NSNull null],
        };
    }
}

#pragma mark - Upload chain

// Override point for tests: creates (but does not resume) the upload task
// for one op. Production always goes through the real NSURLSession; a test
// subclass can override this to count/inspect task creation with no live
// network -- e.g. to prove a doubled -handoffWithOps: never creates a
// second concurrent task. Called with `self.lock` already held.
- (NSURLSessionUploadTask *)createUploadTaskForRequest:(NSURLRequest *)request fromFileURL:(NSURL *)fileURL {
    return [self.session uploadTaskWithRequest:request fromFile:fileURL];
}

- (void)startNextUploadIfNeeded {
    @synchronized(self.lock) {
        if (self.activeTask != nil) return; // one in flight already -- never start a second

        GLTodoOutboxState *state = [self stateFromDisk];
        GLTodoOutboxOp *op = [state nextOpToSend];
        if (op == nil) return; // empty, or halted on a recorded failure

        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@", self.serverBase, op.path]];
        if (url == nil) {
            // Same failure path a real network error takes -- see the
            // class header comment on GL_BAKED_HOST composing a URL that
            // simply fails to resolve/connect rather than raising here.
            GLLog(@"could not build a URL for op %@ path %@", op.opId, op.path);
            GLTodoOutboxState *next = [state stateByApplyingOutcome:GLTodoOutboxOutcomeTransportError status:0];
            [self persistState:next];
            return;
        }

        NSMutableDictionary<NSString *, id> *payload = [op.body mutableCopy] ?: [NSMutableDictionary dictionary];
        payload[@"opId"] = op.opId;
        NSError *jsonError = nil;
        NSData *bodyData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&jsonError];
        if (jsonError || bodyData == nil) {
            GLLog(@"could not serialize body for op %@: %@", op.opId, jsonError);
            GLTodoOutboxState *next = [state stateByApplyingOutcome:GLTodoOutboxOutcomeTransportError status:0];
            [self persistState:next];
            return;
        }

        NSURL *tempFileURL = [NSURL fileURLWithPath:
            [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"gl-todo-outbox-%@.json", [NSUUID UUID].UUIDString]]];
        NSError *writeError = nil;
        if (![bodyData writeToURL:tempFileURL options:NSDataWritingAtomic error:&writeError]) {
            GLLog(@"could not stage body file for op %@: %@", op.opId, writeError);
            GLTodoOutboxState *next = [state stateByApplyingOutcome:GLTodoOutboxOutcomeTransportError status:0];
            [self persistState:next];
            return;
        }

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.HTTPMethod = @"POST";
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

        NSURLSessionUploadTask *task = [self createUploadTaskForRequest:request fromFileURL:tempFileURL];
        task.taskDescription = op.opId;

        self.activeTask = task;
        self.activeResponseData = nil;
        self.activeResponseStatus = 0;
        self.activeTempFileURL = tempFileURL;

        [task resume];
    }
}

#pragma mark - NSURLSessionDataDelegate / NSURLSessionTaskDelegate

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    @synchronized(self.lock) {
        if (dataTask == self.activeTask) {
            NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
            self.activeResponseStatus = status;
            self.activeResponseData = [NSMutableData data];
        }
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    @synchronized(self.lock) {
        if (dataTask == self.activeTask && self.activeResponseData != nil) {
            [self.activeResponseData appendData:data];
        }
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(nullable NSError *)error {
    @synchronized(self.lock) {
        // Identity check is the generation token: -reclaim clears
        // activeTask (after cancelling this exact task) BEFORE releasing
        // the lock, so a callback that reaches this point after a reclaim
        // sees `task != self.activeTask` and does nothing -- no state
        // resurrected, no file written.
        if (task != self.activeTask) return;

        NSInteger status = self.activeResponseStatus;
        NSData *body = self.activeResponseData;
        NSURL *tempFileURL = self.activeTempFileURL;

        self.activeTask = nil;
        self.activeResponseData = nil;
        self.activeResponseStatus = 0;
        self.activeTempFileURL = nil;

        if (tempFileURL != nil) {
            [[NSFileManager defaultManager] removeItemAtURL:tempFileURL error:nil];
        }

        GLTodoOutboxOutcome outcome;
        NSInteger reportedStatus;
        if (error != nil) {
            outcome = GLTodoOutboxOutcomeTransportError;
            reportedStatus = 0;
        } else if (status < 200 || status > 299) {
            outcome = GLTodoOutboxOutcomeHTTPError;
            reportedStatus = status;
        } else if ([GLTodoOutbox responseBodyIndicatesSuccess:body]) {
            outcome = GLTodoOutboxOutcomeSuccess;
            reportedStatus = status;
        } else {
            outcome = GLTodoOutboxOutcomeUnexpectedBody;
            reportedStatus = status;
        }

        GLTodoOutboxState *current = [self stateFromDisk];
        if (current.remaining.count == 0) {
            // Nothing to apply this outcome to -- can only happen if a
            // reclaim raced in between (already guarded above by the
            // identity check) or the store was cleared some other way.
            // Nothing left to do.
            return;
        }
        GLTodoOutboxState *next = [current stateByApplyingOutcome:outcome status:reportedStatus];
        [self persistState:next];

        if (outcome == GLTodoOutboxOutcomeSuccess) {
            [self startNextUploadIfNeeded];
        }
        // Any other outcome halts the chain in place; the web side resumes
        // it by calling outboxReclaim and re-handing-off itself.
    }
}

- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    void (^handler)(void) = self.backgroundEventsCompletionHandler;
    self.backgroundEventsCompletionHandler = nil;
    if (handler != nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            handler();
        });
    }
}

#pragma mark - Success shape

// A captive-portal Wi-Fi (or any misbehaving intermediary) can return 200
// with an HTML body -- that is NOT success, and treating it as such would
// lose the write permanently (the op would be marked sent and dropped from
// `remaining` even though the server never saw it). The real success shape
// (see todo-sorter's lib/routes.mjs -- every mutating route responds
// `{ok: true, ...}` on success) is checked explicitly rather than "any 2xx"
// or "any JSON".
+ (BOOL)responseBodyIndicatesSuccess:(nullable NSData *)data {
    if (data.length == 0) return NO;
    NSError *error = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![parsed isKindOfClass:[NSDictionary class]]) return NO;
    id ok = ((NSDictionary *)parsed)[@"ok"];
    return [ok isKindOfClass:[NSNumber class]] && [(NSNumber *)ok boolValue];
}

@end

NS_ASSUME_NONNULL_END
