#import "QuotesModule.h"

#import "QuotesDailyNotifier.h"
#import "QuotesViewController.h"
#import "GLModuleRegistry.h"

@implementation QuotesModule

// Registers this module with GLModuleRegistry as the runtime loads this
// class, before main() runs. See GLModuleRegistry.m and MODULES.md — every
// GLModule conformer needs this exact +load or it silently never gets a tab.
+ (void)load {
    [GLModuleRegistry registerModule:self];
}

// Tops up the rolling window of daily quote notifications (a no-op delete
// when the feature is off). Skipped under UI tests for the same reason
// EsmeModule skips its permission prompt.
+ (void)moduleDidFinishLaunchingWithOptions:(nullable NSDictionary *)launchOptions {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"UITestSkipNotificationPrompt"]) return;
    [QuotesDailyNotifier refresh];
}

+ (NSString *)moduleTitle { return @"Quotes"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"quote.bubble"]; }

+ (NSInteger)moduleOrder { return 695; }

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
// selected.
+ (BOOL)moduleHandleURL:(NSURL *)url {
    if (![url.scheme isEqualToString:@"overland"]) return NO;
    if (![url.host isEqualToString:@"quotes"]) return NO;
    return [GLModuleRegistry showModuleWithIdentifier:@"GLModule.QuotesModule"];
}

@end
