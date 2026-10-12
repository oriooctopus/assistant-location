#import "SessionsViewController.h"

#import <Security/Security.h>
#import <WebKit/WebKit.h>

#import "GLLog.h"

static NSString *const kSessionsStartVoiceNotification = @"GLSessionsStartVoice";
static NSString *const kSessionsStartTextNotification = @"GLSessionsStartText";
NSString *const kSessionsAttachNotification = @"GLSessionsAttach";
NSString *const kSessionsAttachIDsKey = @"ids";
NSString *const kSessionsHandoffNotification = @"GLSessionsHandoff";
NSString *const kSessionsHandoffIDsKey = @"ids";

// Must match ShareToDesktop/ShareViewController.m. The group is the share
// extension's own application-identifier group (always writable by it);
// Overland.entitlements lists it so this process can read and delete.
static NSString *const kHandoffKeychainService = @"com.oliverullman.assistantlocation.share-handoff";
static NSString *const kHandoffKeychainAccessGroup = @"J66WVM2DTX.com.oliverullman.assistantlocation.share";

// GLWebModuleViewController adopts WKNavigationDelegate privately in its .m,
// so its -webView:didFinishNavigation: isn't visible here; declare it so the
// override below can call super.
@interface GLWebModuleViewController (SessionsNavigationDelegate)
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation;
@end

// A pending call takes the completion it must report `ran` to -- see
// -enqueueJSCall: below for why this isn't a plain no-argument block.
typedef void (^GLSessionsPendingCall)(void (^completion)(BOOL ran));

@interface SessionsViewController ()
// Queue of pending page-function calls (mode selection, then attachment
// ids, in the order they were armed). Tried immediately when armed (covers
// the page already being loaded -- the common case, since the More screen
// usually already exists) AND replayed from -webView:didFinishNavigation:
// for the cold-launch race where the URL arrives before session.html's own
// <script> has run yet -- this replaces the old single
// `pendingModeFunctionName` scalar (a fixed-delay-retry design predates
// even that) now that a deep link can carry both a mode AND an attachment
// list. -didFinishNavigation is a real "the page is loaded" signal, not a
// guess.
//
// A call is removed from this queue the moment it actually RUNS (its
// `ran` completion fires YES) rather than unconditionally after one replay:
// without that, a call armed once (say, on the cold-launch openurl) would
// keep re-firing on every LATER navigation of this same page instance --
// pull-to-refresh, a theme-driven -pushThemeToPageOrReload reload -- each
// one replaying every call still sitting in the queue and duplicating the
// attach/mode action on the page.
@property(nonatomic, strong, nullable) NSMutableArray<GLSessionsPendingCall> *pendingJSCalls;
@end

@implementation SessionsViewController

// Observers go in the DESIGNATED initializer (every init path, including
// -initWithManagedPageNamed:, chains through it), not -viewDidLoad:
// +moduleHandleURL: posts the mode notification right after an animated
// push, and UIKit may not load the view until the transition runs, so a
// -viewDidLoad observer can miss it. Every module's +makeViewController runs
// at launch, so this is alive before any deep link arrives.
- (instancetype)initWithURL:(NSURL *)url displayName:(NSString *)displayName {
    self = [super initWithURL:url displayName:displayName];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(startVoice)
                                                     name:kSessionsStartVoiceNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(startText)
                                                     name:kSessionsStartTextNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(attachIDsReceived:)
                                                     name:kSessionsAttachNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handoffIDsReceived:)
                                                     name:kSessionsHandoffNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)startVoice {
    [self armModeFunction:@"window.startVoiceMode"];
}

- (void)startText {
    [self armModeFunction:@"window.focusTextMode"];
}

- (void)attachIDsReceived:(NSNotification *)notification {
    NSArray<NSString *> *ids = notification.userInfo[kSessionsAttachIDsKey];
    if (ids.count == 0) return;
    [self armAddAttachments:ids];
}

- (void)handoffIDsReceived:(NSNotification *)notification {
    NSArray<NSString *> *ids = notification.userInfo[kSessionsHandoffIDsKey];
    if (ids.count == 0) return;
    [self armAddHandoffImages:ids];
}

static NSMutableDictionary *HandoffQuery(NSString *account) {
    return [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccessGroup: kHandoffKeychainAccessGroup,
        (__bridge id)kSecAttrService: kHandoffKeychainService,
        (__bridge id)kSecAttrAccount: account,
    } mutableCopy];
}

// Photos the share extension left in the shared keychain (no upload there;
// the page uploads, or queues the Start until it can). The keychain read
// happens inside the queued call so a cold-launch replay re-reads; the items
// are deleted only once the page reports it ran the call. A missing or
// unreadable item is logged and skipped, never silently ignored.
- (void)armAddHandoffImages:(NSArray<NSString *> *)ids {
    __weak __typeof(self) weakSelf = self;
    [self enqueueJSCall:^(void (^completion)(BOOL ran)) {
        NSMutableArray<NSDictionary *> *files = [NSMutableArray array];
        NSMutableArray<NSString *> *readIDs = [NSMutableArray array];
        for (NSString *itemID in ids) {
            NSMutableDictionary *query = HandoffQuery(itemID);
            query[(__bridge id)kSecReturnData] = @YES;
            query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
            CFTypeRef result = NULL;
            OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
            if (status != errSecSuccess || !result) {
                GLLog(@"Sessions handoff: SecItemCopyMatching failed for %@ (OSStatus %d) -- photo NOT attached",
                      itemID, (int)status);
                continue;
            }
            NSData *data = CFBridgingRelease(result);
            [files addObject:@{@"type": @"image/jpeg", @"data": [data base64EncodedStringWithOptions:0]}];
            [readIDs addObject:itemID];
        }
        if (files.count == 0) {
            // Nothing readable and nothing to retry: drop the call so it does
            // not replay forever (the loss is already logged per item).
            completion(YES);
            return;
        }
        [weakSelf callWebFunctionIfDefined:@"addAttachmentFiles"
                          withJSONArgument:files
                                completion:^(BOOL ran) {
            if (ran) {
                for (NSString *itemID in readIDs) {
                    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)HandoffQuery(itemID));
                    if (status != errSecSuccess) {
                        GLLog(@"Sessions handoff: SecItemDelete failed for %@ (OSStatus %d)", itemID, (int)status);
                    }
                }
            }
            completion(ran);
        }];
    }];
}

// Enqueues the call AND tries it immediately -- see the pendingJSCalls doc
// comment above for why both.
- (void)armModeFunction:(NSString *)functionName {
    __weak __typeof(self) weakSelf = self;
    [self enqueueJSCall:^(void (^completion)(BOOL ran)) {
        [weakSelf callWebFunctionIfDefined:functionName completion:completion];
    }];
}

// SessionsModule.m's +moduleHandleURL: validates the ids against the uuid.ext
// pattern before this ever runs, so no further validation happens here --
// this just forwards the already-clean list into the page contract
// (window.addAttachments(ids)).
- (void)armAddAttachments:(NSArray<NSString *> *)ids {
    __weak __typeof(self) weakSelf = self;
    [self enqueueJSCall:^(void (^completion)(BOOL ran)) {
        [weakSelf callWebFunctionIfDefined:@"addAttachments" withJSONArgument:ids completion:completion];
    }];
}

// Adds `call` to the queue, then runs it right away. `call` reports back
// via its own completion whether it actually ran (the page had the function
// defined) -- on YES, the exact same call object is removed from the queue
// (default block -isEqual: is pointer identity, and `call` here is that
// same instance), so a later navigation's replay in
// -webView:didFinishNavigation: only ever re-attempts calls that never
// successfully ran.
- (void)enqueueJSCall:(GLSessionsPendingCall)call {
    if (!self.pendingJSCalls) {
        self.pendingJSCalls = [NSMutableArray array];
    }
    GLSessionsPendingCall queued = [call copy];
    [self.pendingJSCalls addObject:queued];
    [self attemptPendingCall:queued];
}

- (void)attemptPendingCall:(GLSessionsPendingCall)call {
    __weak __typeof(self) weakSelf = self;
    call(^(BOOL ran) {
        if (!ran) return;
        [weakSelf.pendingJSCalls removeObject:call];
    });
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [super webView:webView didFinishNavigation:navigation];
    // Snapshot before replaying: a call's own completion above mutates
    // pendingJSCalls (removing itself on success), so iterating the live
    // array while its contents change under us is exactly the bug this
    // whole queue exists to avoid.
    NSArray<GLSessionsPendingCall> *calls = [self.pendingJSCalls copy];
    for (GLSessionsPendingCall call in calls) {
        [self attemptPendingCall:call];
    }
}

@end
