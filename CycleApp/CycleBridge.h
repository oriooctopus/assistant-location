#import <Foundation/Foundation.h>

@class CycleStore, CycleNotifier;

/// Native side of the page <-> shell contract (handler name `cycle`).
/// JS -> native: {id, cmd, args}. Native answers with window.__cycleReply(id, result, error).
/// Commands: store.get/set/keys, notify.permission/status/schedule/cancel, app.openSettings, speech.start/speech.stop, haptic, share, share.text, clipboard.set, lock.get/set,
/// creds.set/get/clear (Keychain), ready.
/// Native -> JS: window.cycleNative.route(route) (queued until the page sends `ready`) and
/// window.cycleNative.foreground() (only once the page is ready), window.cycleNative.pushToken(hex) (on `ready` and when a token arrives),
/// window.cycleNative.speech(text, final) and window.cycleNative.speechError(message) while speech.start is capturing.
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

/// Starts live speech-to-text (the `speech.start` command); `done(nil)` once capturing, else a short reason ("Mic off" when denied).
/// Wired by the view controller. The transcript comes back through deliverSpeech:final:.
@property (nonatomic, copy) void (^speechStart)(void (^done)(NSString *error));
/// Stops it and releases the microphone (the `speech.stop` command). Wired by the view controller.
@property (nonatomic, copy) void (^speechStop)(void);

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
/// The APNs device token (hex): remembered, and handed to the page as cycleNative.pushToken(hex) whenever it is
/// ready (now, and again after each page reload), so the page can register it with the box.
- (void)deliverPushToken:(NSString *)hex;
/// Transcript so far -> window.cycleNative.speech(text, final); `final` = capture ended.
- (void)deliverSpeech:(NSString *)text final:(BOOL)final;
/// A running capture failed -> window.cycleNative.speechError(message).
- (void)deliverSpeechError:(NSString *)message;
/// The app is leaving the foreground: stop any capture and tell the page it ended.
- (void)speechInterrupted;
/// The app became active.
- (void)foreground;
/// The web view started a new navigation: the new page must send `ready` again.
- (void)pageWillReload;

@end
