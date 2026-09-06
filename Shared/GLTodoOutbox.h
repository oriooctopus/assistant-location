// Native half of the Todos tab's offline write queue. The web app (todo-sorter,
// see Modules/Todos/TodosViewController.m) keeps its own in-memory/localStorage
// write queue while the page is alive; this class is what drains that queue
// in the BACKGROUND, via a background NSURLSession, so a swipe made on a bad
// connection still reaches the server hours later even if the app is
// suspended or was killed and relaunched by the OS for exactly this reason.
//
// Ownership handoff (see GLWebBridge.h's outboxHandoff/outboxReclaim doc
// comment for the wire protocol):
//
//   - The web page owns the queue while it is alive/visible.
//   - `outboxHandoff` transfers ownership to native: REPLACES the stored
//     outbox with exactly the ops given, in order, and starts (or resumes)
//     draining it. Idempotent — calling it twice with the same ops is a
//     no-op the second time (see -handoffWithOps: for the identical-array
//     short-circuit this requires).
//   - `outboxReclaim` transfers ownership back to the page: halts the
//     upload chain, clears the store, and reports what was sent / what
//     remains / what failed so the page can resume from exactly that state.
//
// Persistence: every state change (queue replaced, an op moves from
// `remaining` to `sent`, a failure recorded) is written to disk with
// -persist BEFORE the next network call starts. The app can be killed by
// the OS at any point -- a "sent" marker that only ever lived in memory
// loses that boundary on relaunch, and a background NSURLSession's
// completion delegate callback can itself fire after a kill-and-relaunch
// (that's the whole point of a background session), so the on-disk file is
// the only durable record.
//
// Sequencing: strictly one upload in flight at a time, in `remaining`'s
// array order (index 0 first). The server's /api/undo is stack-relative, so
// reordering ops can pop the wrong entry -- see
// -[GLTodoOutboxState stateByApplyingOutcome:status:]'s doc comment for the
// exact rule this enforces. A failed op halts the chain in
// place; it is never retried or skipped by this class -- the web side owns
// conflict arbitration for a failed write and will re-send it itself (every
// op carries an opId and the server dedupes on it, so a resend of something
// already applied is a no-op there).
//
// Cold relaunch: `activeTask` (the in-memory pointer to whatever upload is
// in flight) does NOT survive a kill-and-relaunch -- it is nil the instant
// this object exists in the new process, even if the background session it
// wraps genuinely still has that same upload running. -init... calls
// -adoptOutstandingUploadOrResumeChain exactly once for this reason: it asks
// the session itself (which DOES survive) whether the on-disk head op's
// upload is still outstanding, adopts it as `activeTask` if so, and
// otherwise starts the next upload. Without this, every completion
// delegate callback for a surviving upload is silently dropped by the
// `task != self.activeTask` staleness guard in
// -URLSession:task:didCompleteWithError: (see GLTodoOutbox.m) -- the op
// itself is never lost (the web page still holds it and the server dedupes
// on opId), but the background drain would silently stop forever.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One queued write: `path` is an /api/* route (e.g. "/api/swipe"), `body`
/// is the JSON-able params object the page would have sent as the POST
/// body (opId is NOT expected to already be in here -- see
/// -handoffWithOps:).
@interface GLTodoOutboxOp : NSObject <NSCopying>
@property(nonatomic, copy, readonly) NSString *opId;
@property(nonatomic, copy, readonly) NSString *path;
@property(nonatomic, copy, readonly) NSDictionary<NSString *, id> *body;

- (instancetype)initWithOpId:(NSString *)opId path:(NSString *)path body:(NSDictionary<NSString *, id> *)body;

/// Parses `{opId, path, body}` as sent over the bridge. Returns nil (and
/// never partially constructs) if any of the three is missing or the wrong
/// type -- a malformed op in a handoff call is a bridge-level protocol
/// violation, not something to silently coerce.
+ (nullable instancetype)opFromDictionary:(NSDictionary *)dictionary;

/// The wire/on-disk representation: `{opId, path, body}`.
- (NSDictionary<NSString *, id> *)toDictionary;

@end

/// The outcome of one completed upload task, as fed into
/// -[GLTodoOutboxState stateByApplyingOutcome:status:] (declared below).
/// Deliberately a plain enum plus a status code rather than an NSError --
/// the state machine only ever needs to know which bucket a completion
/// falls into.
typedef NS_ENUM(NSInteger, GLTodoOutboxOutcome) {
    /// 2xx status AND a JSON body shaped like todo-sorter's real success
    /// response (an object with `ok == true` at the top level -- see
    /// GLTodoOutbox.m's comment on why this is the check, not just "any
    /// JSON" or "any 2xx").
    GLTodoOutboxOutcomeSuccess,
    /// A transport-level failure (no response at all: offline, DNS, timeout,
    /// cancelled). Reported status is 0 in this case.
    GLTodoOutboxOutcomeTransportError,
    /// A response came back but the status was not 2xx.
    GLTodoOutboxOutcomeHTTPError,
    /// 2xx status but the body did NOT parse as `{ok: true, ...}` JSON --
    /// e.g. a captive-portal login page (200 + HTML). Treated as a failure,
    /// never as sent, because treating it as sent would lose the write
    /// permanently.
    GLTodoOutboxOutcomeUnexpectedBody,
};

/// current + outcome -> next. A plain instance method (not tied to
/// NSURLSession in any way) so the sequencing decision (does this op move
/// to `sent`? does the chain stop? what gets
/// recorded in `failed`?) can be unit-tested with no live NSURLSession.
///
/// Contract: on GLTodoOutboxOutcomeSuccess, `remaining`'s head op moves to
/// `sent` (appended), `failed` is cleared, and the chain should continue
/// with the new head (if any). On any other outcome, `remaining` is
/// UNCHANGED (the failed op stays at the head, never skipped and never
/// retried by this class -- see the header doc comment above) and `failed`
/// is set to `{opId, status}` (status 0 for a transport error). The caller
/// stops the chain whenever the returned state's `failed` is non-nil.
@interface GLTodoOutboxState : NSObject <NSCopying>
@property(nonatomic, copy, readonly) NSArray<GLTodoOutboxOp *> *remaining;
@property(nonatomic, copy, readonly) NSArray<GLTodoOutboxOp *> *sent;
/// `{opId, status}` or nil. `status` is an NSNumber (NSInteger), 0 for a
/// transport error.
@property(nonatomic, copy, readonly, nullable) NSDictionary<NSString *, id> *failed;

- (instancetype)initWithRemaining:(NSArray<GLTodoOutboxOp *> *)remaining
                             sent:(NSArray<GLTodoOutboxOp *> *)sent
                           failed:(nullable NSDictionary<NSString *, id> *)failed;

/// The empty state (nothing queued, nothing sent, no failure) -- what a
/// fresh install or a just-reclaimed store looks like.
+ (instancetype)emptyState;

/// Applies `outcome` (with `status`/`error` as appropriate -- ignored for a
/// Success outcome) to `self.remaining`'s head op. Precondition: `remaining`
/// is non-empty (the caller never has a task in flight for an empty queue).
- (GLTodoOutboxState *)stateByApplyingOutcome:(GLTodoOutboxOutcome)outcome status:(NSInteger)status;

/// The op that would be uploaded next, or nil if there is nothing queued or
/// the chain is halted on a failure.
- (nullable GLTodoOutboxOp *)nextOpToSend;

@end

/// The persistent, network-driving singleton. See the file header comment
/// above for the ownership-handoff design this exists to implement.
@interface GLTodoOutbox : NSObject <NSURLSessionTaskDelegate, NSURLSessionDataDelegate>

/// Stable background-session identifier -- must match what AppDelegate hands
/// back into -handleEventsForBackgroundURLSessionCompletion: on relaunch, so
/// this session's delegate is the one iOS reconnects to.
+ (NSString *)backgroundSessionIdentifier;

+ (instancetype)sharedOutbox;

/// Set by AppDelegate from -application:handleEventsForBackgroundURLSession:
/// completionHandler:. Called (dispatched to the main queue, then cleared)
/// from -URLSessionDidFinishEventsForBackgroundURLSession: -- this is what
/// lets iOS suspend the app again once every delegate callback for the
/// relaunch has been delivered and processed.
@property(nonatomic, copy, nullable) void (^backgroundEventsCompletionHandler)(void);

/// -[NSFileManager applicationSupportDirectory]-relative store location, so
/// tests can point a throwaway instance at a temp file instead of the real
/// one. Exposed for tests only; production code always uses
/// +sharedOutbox's own file.
+ (NSURL *)defaultStoreURL;

/// Test seam: builds an outbox that persists to `storeURL` and uploads
/// against `serverBase` (e.g. "http://127.0.0.1:8399"), using
/// `configuration` to build its own NSURLSession (always with `self` as
/// delegate -- an already-built NSURLSession can't be handed in here, since
/// its delegate would have had to be set before this instance existed).
/// `configuration` nil means the real production background session; a
/// test passes e.g. `[NSURLSessionConfiguration ephemeralSessionConfiguration]`
/// for a fast, non-background session instead. Never used by app code.
- (instancetype)initWithStoreURL:(NSURL *)storeURL
                       serverBase:(NSString *)serverBase
              sessionConfiguration:(nullable NSURLSessionConfiguration *)configuration NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Current on-disk state, reloaded fresh from disk (not cached in memory)
/// so a test can assert on exactly what a prior call persisted.
- (GLTodoOutboxState *)loadState;

/// `outboxHandoff` bridge method: REPLACES the stored outbox with `ops` (in
/// order) and starts/resumes the upload chain. Returns the number of ops
/// accepted. Idempotent: calling this again with an outbox-content-
/// identical `ops` array (same opIds in the same order) while there is no
/// recorded failure is a no-op -- it does not restart an in-flight upload
/// or re-persist -- covering the `hidden` + `pagehide` double-fire case in
/// the header comment above.
- (NSInteger)handoffWithOps:(NSArray<GLTodoOutboxOp *> *)ops;

/// `outboxReclaim` bridge method: halts the chain (cancelling any in-flight
/// task) and clears the store, returning what to hand back to the page --
/// `sent` opIds, `remaining` ops (full {opId, path, body} dictionaries), and
/// `failed` (`{opId, status}` or nil). Leaves the store empty afterward: a
/// completion callback for the just-cancelled task that fires after this
/// call returns must not resurrect any state or write a stale file (see
/// GLTodoOutbox.m's generation-token comment).
- (NSDictionary<NSString *, id> *)reclaim;

/// Override point for tests: creates (but does not resume) the upload task
/// for one op. Production code always calls through to the real
/// NSURLSession; a test subclass can override this to count/inspect task
/// creation with no live network -- e.g. to prove a doubled
/// -handoffWithOps: never creates a second concurrent task. Called with
/// this object's internal lock already held -- do not call back into any
/// other GLTodoOutbox method from an override.
- (NSURLSessionUploadTask *)createUploadTaskForRequest:(NSURLRequest *)request fromFileURL:(NSURL *)fileURL;

/// Override point for tests: asks the session which upload tasks it still
/// has outstanding. Production calls through to the real NSURLSession's
/// -getTasksWithCompletionHandler: -- this is how
/// -adoptOutstandingUploadOrResumeChain discovers a task that survived a
/// cold relaunch (see that method's doc comment). A test subclass can
/// override this to hand back a task it created directly against a fake
/// protocol, simulating a relaunch with no real background-session
/// identifier collision (you cannot have two live NSURLSessions sharing one
/// background identifier in the same process).
- (void)getOutstandingUploadTasksWithCompletionHandler:(void (^)(NSArray<NSURLSessionUploadTask *> *tasks))completionHandler;

/// The fix for the cold-relaunch bug: `activeTask` is memory-only, so a
/// freshly-launched process always starts with it nil, even when this
/// object's background session actually still has an upload in flight from
/// before the relaunch. Called once, automatically, the moment the real
/// (non-test) background session is created -- asks the session (via
/// -getOutstandingUploadTasksWithCompletionHandler:) whether the on-disk
/// head op's upload genuinely survived, and adopts it as `activeTask` if so
/// (so its eventual delegate callback is applied instead of being dropped
/// by the `task != self.activeTask` staleness guard -- see GLTodoOutbox.m).
/// Otherwise resumes the chain via -startNextUploadIfNeeded. Never starts a
/// second concurrent upload: if anything else (e.g. a fresh handoff) has
/// already set `activeTask` by the time the (asynchronous) answer comes
/// back, this is a no-op. Exposed here so a test can invoke it directly to
/// simulate a relaunch.
- (void)adoptOutstandingUploadOrResumeChain;

/// The real todo-sorter success shape: a 2xx alone is not enough (a
/// captive-portal Wi-Fi can return 200 with an HTML body), so this checks
/// the body itself parses as JSON of the object shape every mutating route
/// in todo-sorter's lib/routes.mjs actually returns on success -- `{ok:
/// true, ...}`. Exposed (not just used internally) so it can be unit-tested
/// directly with no live session.
+ (BOOL)responseBodyIndicatesSuccess:(nullable NSData *)data;

@end

NS_ASSUME_NONNULL_END
