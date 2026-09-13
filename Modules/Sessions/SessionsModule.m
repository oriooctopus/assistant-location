#import "SessionsModule.h"

#import "GLModuleRegistry.h"
#import "SessionsViewController.h"

static NSString *const kSessionsStartVoiceNotification = @"GLSessionsStartVoice";
static NSString *const kSessionsStartTextNotification = @"GLSessionsStartText";

// Matches ShareToDesktop's /sessions/upload response id shape exactly:
// <uuid>.<ext>, ext restricted to what the server actually accepts (see
// events/server.py's magic-byte sniff). An id that fails this is dropped
// rather than forwarded -- the page contract (window.addAttachments) takes
// bare ids and turns them straight into an image src, so anything let
// through here is effectively unsanitized input reaching the page.
static NSString *const kAttachIDPattern =
    @"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\.(png|jpg|gif|webp)$";

@implementation SessionsModule

// See AutoJournalModule.m's +load doc comment -- every GLModule conformer
// needs this exact pattern or it silently never gets a tab/tile.
+ (void)load {
    [GLModuleRegistry registerModule:self];
}

+ (NSString *)moduleTitle { return @"New Session"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"terminal"]; }

// 660: right after Events (650), the last of the five More-grid overflow
// modules today -- see MODULES.md's order list, which this must stay in
// sync with.
+ (NSInteger)moduleOrder { return 660; }

// Return the page controller directly, NOT wrapped in its own
// UINavigationController -- unlike AutoJournalModule (a top-level TAB,
// which needs its own nav controller to push its "Recent" screen), Sessions
// is a More-OVERFLOW module: GLModuleRegistry's
// +openModuleViewController:ontoNavigationController: (see
// GLModuleRegistry.m) PUSHES an overflow module onto the shared More-screen
// nav stack (moreCoordinator.moreNav) itself. Wrapping here doubled up the
// nav bar (native "New Session" title bar stacked over the page's own
// gl-header) and broke the page's Back button: `goBack` pops the
// CONTAINING nav controller, and popping a nav controller that IS the
// stack's root (this module's own, self-wrapped one) is a no-op -- exactly
// SettingsModule.m's pattern, which this now matches.
+ (UIViewController *)makeViewController {
    return [[SessionsViewController alloc] initWithManagedPageNamed:@"session.html"];
}

// Entry point for the JournalControl-style lock-screen Controls added by
// this task ("New session (voice)"/"New session (text)") -- mirrors
// AutoJournalModule.m's +moduleHandleURL: exactly (same URL-as-cross-process
// -channel reasoning documented there: openWhenRun launches the app but runs
// perform() in the WIDGET EXTENSION's process, so a URL delivered to
// SceneDelegate is the only thing that reaches app-process code either
// cold or warm).
//
// Unlike AutoJournalModule (a top-level tab, so its notification observer
// -- AutoJournalViewController's own -init -- is guaranteed to already be
// alive by the time this fires), Sessions is a More-overflow module: its
// SessionsViewController IS still built once up front by GLModuleRegistry
// (see registerModule:), so the observer is alive too, but the page itself
// is only BROUGHT ON SCREEN here via openOverflowModuleWithIdentifier: --
// so this method does both: open the screen, then post the mode
// notification for SessionsViewController to forward into the page.
+ (BOOL)moduleHandleURL:(NSURL *)url {
    if (![url.scheme isEqualToString:@"overland"]) return NO;
    if (![url.host isEqualToString:@"session"]) return NO;

    NSString *mode = [url.path stringByReplacingOccurrencesOfString:@"/" withString:@""];
    NSString *notificationName = nil;
    if ([mode isEqualToString:@"voice"]) {
        notificationName = kSessionsStartVoiceNotification;
    } else if ([mode isEqualToString:@"text"]) {
        notificationName = kSessionsStartTextNotification;
    } else {
        return NO;
    }

    [GLModuleRegistry openOverflowModuleWithIdentifier:@"GLModule.SessionsModule"];
    [[NSNotificationCenter defaultCenter] postNotificationName:notificationName object:nil];

    NSArray<NSString *> *attachIDs = [self validAttachIDsFromURL:url];
    if (attachIDs.count > 0) {
        [[NSNotificationCenter defaultCenter] postNotificationName:kSessionsAttachNotification
                                                             object:nil
                                                           userInfo:@{kSessionsAttachIDsKey : attachIDs}];
    }
    return YES;
}

// Shared by ShareToDesktop's "Start conversation" button
// (overland://session/text?attach=<id1>,<id2>) -- see MODULES.md and
// ShareToDesktop/ShareViewController.m. Comma-separated, each id checked
// against kAttachIDPattern; anything that doesn't match is dropped rather
// than forwarded, since window.addAttachments turns a bare id straight into
// an image src on the page.
+ (NSArray<NSString *> *)validAttachIDsFromURL:(NSURL *)url {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString *rawList = nil;
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"attach"]) {
            rawList = item.value;
            break;
        }
    }
    if (rawList.length == 0) return @[];

    static NSRegularExpression *idRegex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        idRegex = [NSRegularExpression regularExpressionWithPattern:kAttachIDPattern options:0 error:NULL];
    });

    NSMutableArray<NSString *> *valid = [NSMutableArray array];
    for (NSString *candidate in [rawList componentsSeparatedByString:@","]) {
        NSRange fullRange = NSMakeRange(0, candidate.length);
        NSTextCheckingResult *match = [idRegex firstMatchInString:candidate options:0 range:fullRange];
        if (match && NSEqualRanges(match.range, fullRange)) {
            [valid addObject:candidate];
        }
    }
    return valid;
}

@end
