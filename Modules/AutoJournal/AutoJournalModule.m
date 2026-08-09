#import "AutoJournalModule.h"

#import "AutoJournalViewController.h"
#import "GLModuleRegistry.h"

@implementation AutoJournalModule

// Registers this module with GLModuleRegistry as the runtime loads this
// class, before main() runs. See GLModuleRegistry.m and MODULES.md — every
// GLModule conformer needs this exact +load or it silently never gets a tab.
+ (void)load {
    [GLModuleRegistry registerModule:self];
}

+ (NSString *)moduleTitle { return @"Journal"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"mic.circle.fill"]; }

+ (NSInteger)moduleOrder { return 100; }

+ (UIViewController *)makeViewController {
    // Wrapped in a UINavigationController so the Journal tab can push the
    // "Recent" recordings screen (see AutoJournalViewController's rightBarButtonItem)
    // — no module here already had a nav bar, so this module owns adding its own.
    AutoJournalViewController *journal = [[AutoJournalViewController alloc] init];
    return [[UINavigationController alloc] initWithRootViewController:journal];
}

@end
