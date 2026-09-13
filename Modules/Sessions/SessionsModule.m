#import "SessionsModule.h"

#import "GLModuleRegistry.h"
#import "SessionsViewController.h"

static NSString *const kSessionsStartVoiceNotification = @"GLSessionsStartVoice";
static NSString *const kSessionsStartTextNotification = @"GLSessionsStartText";

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

+ (UIViewController *)makeViewController {
    SessionsViewController *sessions = [[SessionsViewController alloc] initWithManagedPageNamed:@"session.html"];
    return [[UINavigationController alloc] initWithRootViewController:sessions];
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
    return YES;
}

@end
