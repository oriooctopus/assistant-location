#import "QuotesModule.h"

#import "QuotesViewController.h"
#import "GLModuleRegistry.h"

@implementation QuotesModule

// Registers this module with GLModuleRegistry as the runtime loads this
// class, before main() runs. See GLModuleRegistry.m and MODULES.md — every
// GLModule conformer needs this exact +load or it silently never gets a tab.
+ (void)load {
    [GLModuleRegistry registerModule:self];
}

+ (NSString *)moduleTitle { return @"Quotes"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"quote.bubble"]; }

+ (NSInteger)moduleOrder { return 670; }

+ (UIViewController *)makeViewController {
    // Wrapped in a UINavigationController, same reasoning as
    // AutoJournalModule.m: the Schedule tab pushes a rule-edit screen, and
    // no module here already owns a nav bar this could ride on.
    QuotesViewController *root = [[QuotesViewController alloc] init];
    return [[UINavigationController alloc] initWithRootViewController:root];
}

// The widget's (Stage 2, JournalControl/QuotesWidget.swift) widgetURL is
// "overland://quotes" -- tapping it should land on the Quotes tab
// specifically, not just launch the app onto whatever tab was last
// selected. Unlike Sessions/AutoJournal's +moduleHandleURL: (see those
// files), Quotes is a plain top-level tab, not a More-overflow module, and
// GLModuleRegistry's +routeURL: calls this with no view-controller context
// to hang a tab-bar lookup off of -- so this resolves the key window's
// root UITabBarController itself (the app's one and only shell shape;
// see MODULES.md) rather than adding a new registry-wide hook for a single
// caller.
+ (BOOL)moduleHandleURL:(NSURL *)url {
    if (![url.scheme isEqualToString:@"overland"]) return NO;
    if (![url.host isEqualToString:@"quotes"]) return NO;

    UIWindow *keyWindow = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) { keyWindow = window; break; }
        }
        if (keyWindow != nil) break;
    }
    UIViewController *root = keyWindow.rootViewController;
    if (root == nil) return NO;

    return [GLModuleRegistry selectTabWithIdentifier:@"GLModule.QuotesModule" fromViewController:root];
}

@end
