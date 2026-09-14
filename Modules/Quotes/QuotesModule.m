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

@end
