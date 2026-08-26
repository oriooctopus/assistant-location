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

// 700 keeps it past the four visible tabs, in the More bucket with
// Settings and Upload.
+ (NSInteger)moduleOrder { return 700; }

+ (UIViewController *)makeViewController {
    return [[FinancesViewController alloc] init];
}

@end
