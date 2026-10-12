#import "SessionsModule.h"

#import "GLModuleRegistry.h"
#import "SessionsViewController.h"

static NSString *const kSessionsStartVoiceNotification = @"GLSessionsStartVoice";
static NSString *const kSessionsStartTextNotification = @"GLSessionsStartText";

// Matches the /sessions/upload response id shape exactly:
// <uuid>.<ext>, ext restricted to what the server actually accepts (see
// location-server/lib/sessions.mjs's magic-byte sniff). An id that fails
// this is dropped rather than forwarded -- the page contract
// (window.addAttachments) takes bare ids and turns them straight into an
// image src, so anything let through here is effectively unsanitized input
// reaching the page.
static NSString *const kAttachIDPattern =
    @"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\.(png|jpg|gif|webp)$";

// Keychain handoff items from ShareToDesktop are named by a bare UUID
// (ShareViewController.m's account). Anything else is dropped before it can
// reach a SecItem query or the page.
static NSString *const kHandoffIDPattern =
    @"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$";

@implementation SessionsModule

// See AutoJournalModule.m's +load doc comment -- every GLModule conformer
// needs this exact pattern or it silently never gets a tab/tile.
+ (void)load {
    [GLModuleRegistry registerModule:self];
}

+ (NSString *)moduleTitle { return @"New Session"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"terminal"]; }

// 50: the first visible tab (it took Growth's slot; Growth moved into the
// More grid at 660) -- see MODULES.md's order list, which this must stay in
// sync with.
+ (NSInteger)moduleOrder { return 50; }

// Return the page controller directly, NOT wrapped in its own
// UINavigationController -- unlike AutoJournalModule (a top-level TAB,
// which needs its own nav controller to push its "Recent" screen), Sessions
// has no pushed screens: session.html swaps its list/detail views in-page.
// It sits directly in the tab bar like Growth/Events/Todos did (all plain
// GLWebModuleViewController tabs). Wrapping it would stack a native nav bar
// over the page's own gl-header. As a tab root there is no containing nav
// controller, so the page hides its Back button outside the detail view
// (session.html) rather than calling `goBack`.
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
// Like AutoJournalModule (a top-level tab), Sessions' notification observer
// -- SessionsViewController's designated init -- is alive by the time this
// fires, since GLModuleRegistry builds every module's controller up front.
// The page itself is only BROUGHT ON SCREEN here via
// showModuleWithIdentifier: (which selects its tab) -- so this method does
// both: select the tab, then post the mode notification for
// SessionsViewController to forward into the page.
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

    [GLModuleRegistry showModuleWithIdentifier:@"GLModule.SessionsModule"];
    [[NSNotificationCenter defaultCenter] postNotificationName:notificationName object:nil];

    NSArray<NSString *> *attachIDs = [self validAttachIDsFromURL:url];
    if (attachIDs.count > 0) {
        [[NSNotificationCenter defaultCenter] postNotificationName:kSessionsAttachNotification
                                                             object:nil
                                                           userInfo:@{kSessionsAttachIDsKey : attachIDs}];
    }

    NSArray<NSString *> *handoffIDs = [self validHandoffIDsFromURL:url];
    if (handoffIDs.count > 0) {
        [[NSNotificationCenter defaultCenter] postNotificationName:kSessionsHandoffNotification
                                                             object:nil
                                                           userInfo:@{kSessionsHandoffIDsKey : handoffIDs}];
    }
    return YES;
}

// ShareToDesktop's "Start conversation" button stashes the photos in the
// shared keychain (no network) and opens
// overland://session/text?handoff=<uuid1>,<uuid2>; the ids name keychain
// items SessionsViewController reads and feeds to the page. Same
// comma-separated, drop-what-doesn't-match shape as `attach=`.
+ (NSArray<NSString *> *)validHandoffIDsFromURL:(NSURL *)url {
    return [self validIDsNamed:@"handoff" pattern:kHandoffIDPattern fromURL:url];
}

// Shared by ShareToDesktop's "Start conversation" button
// (overland://session/text?attach=<id1>,<id2>) -- see MODULES.md and
// ShareToDesktop/ShareViewController.m. Comma-separated, each id checked
// against kAttachIDPattern; anything that doesn't match is dropped rather
// than forwarded, since window.addAttachments turns a bare id straight into
// an image src on the page.
+ (NSArray<NSString *> *)validAttachIDsFromURL:(NSURL *)url {
    return [self validIDsNamed:@"attach" pattern:kAttachIDPattern fromURL:url];
}

+ (NSArray<NSString *> *)validIDsNamed:(NSString *)queryName
                               pattern:(NSString *)pattern
                               fromURL:(NSURL *)url {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString *rawList = nil;
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:queryName]) {
            rawList = item.value;
            break;
        }
    }
    if (rawList.length == 0) return @[];

    NSRegularExpression *idRegex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];

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
