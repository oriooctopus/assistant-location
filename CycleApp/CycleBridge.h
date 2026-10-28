#import <Foundation/Foundation.h>

@class CycleStore, CycleNotifier;

/// Native side of the page <-> shell contract (handler name `cycle`).
/// JS -> native: {id, cmd, args}. Native answers with window.__cycleReply(id, result, error).
/// Commands: store.get/set/keys, notify.permission/status/schedule/cancel, app.openSettings, haptic, share, share.text, clipboard.set, lock.get/set,
/// creds.set/get/clear (Keychain), ready.
/// Native -> JS: window.cycleNative.route(route) (queued until the page sends `ready`) and
/// window.cycleNative.foreground() (only once the page is ready).
/// Everything runs on the main thread; script evaluation goes through `evaluateJS` so the bridge
/// has no WebKit dependency.
@interface CycleBridge : NSObject

@property (nonatomic, copy) void (^evaluateJS)(NSString *js);
/// Presents the system share sheet for these activity items (an NSURL for `share`, an NSString for `share.text`). Wired by the view controller.
@property (nonatomic, copy) void (^presentItems)(NSArray *items);

/// Puts a string on the system pasteboard (the `clipboard.set` command). Wired by the view controller.
@property (nonatomic, copy) void (^setClipboard)(NSString *text);

/// Fired on the main thread after lock.set changes the Face ID flag. Wired by the view controller.
@property (nonatomic, copy) void (^lockChanged)(void);

/// Opens this app's page in iOS Settings (the `app.openSettings` command). Wired by the view controller.
@property (nonatomic, copy) void (^openSettings)(void);

/// The Face ID app-lock flag (NSUserDefaults, default ON).
+ (BOOL)lockEnabled;

/// YES until the first successful Face ID unlock; lock.set resets it, so turning the lock on asks once more.
+ (BOOL)lockNeedsAuth;
+ (void)markLockPassed;

- (instancetype)initWithStore:(CycleStore *)store notifier:(CycleNotifier *)notifier;

/// A script message body from the page; the reply goes out through `evaluateJS` on the main queue.
- (void)handleMessage:(id)body;
/// Runs one command; `done(result, error)` fires exactly once (error nil = success), possibly
/// asynchronously. handleMessage: wraps this with the reply plumbing.
- (void)dispatchCommand:(NSString *)cmd args:(NSDictionary *)args completion:(void (^)(id result, NSString *error))done;
/// A notification was tapped: deliver now if the page is ready, else queue.
- (void)deliverRoute:(NSString *)route;
/// The app became active.
- (void)foreground;
/// The web view started a new navigation: the new page must send `ready` again.
- (void)pageWillReload;

@end
