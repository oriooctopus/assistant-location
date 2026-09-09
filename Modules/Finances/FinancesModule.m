#import "FinancesModule.h"

#import "FinancesViewController.h"
#import "GLModuleRegistry.h"

@implementation FinancesModule

// Registers this module with GLModuleRegistry as the runtime loads this
// class, before main() runs. See GLModuleRegistry.m and MODULES.md — every
// GLModule conformer needs this exact +load or it silently never gets a tab.
+ (void)load {
    [GLModuleRegistry registerModule:self];
}

+ (NSString *)moduleTitle { return @"Finances"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"dollarsign.circle"]; }

// 610 (was 50): moved out of the visible tab bar into the More grid to make
// room for Esme, which now owns Finances' old slot (see EsmeModule.m). Sits
// between Upload (600) and AutoJournal/Journal (620) so it doesn't disturb
// Journal/Events staying last in the More grid -- bottom row, easiest thumb
// reach, see MODULES.md's order list and more.html's DEFAULT_ORDER comment.
+ (NSInteger)moduleOrder { return 610; }

+ (UIViewController *)makeViewController {
    return [[FinancesViewController alloc] init];
}

@end
