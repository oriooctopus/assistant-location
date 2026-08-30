#import "GrowthModule.h"

#import "GrowthViewController.h"
#import "GLModuleRegistry.h"

@implementation GrowthModule

// Registers this module with GLModuleRegistry as the runtime loads this
// class, before main() runs. See GLModuleRegistry.m and MODULES.md — every
// GLModule conformer needs this exact +load or it silently never gets a tab.
+ (void)load {
    [GLModuleRegistry registerModule:self];
}

+ (NSString *)moduleTitle { return @"Growth"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"leaf"]; }

+ (NSInteger)moduleOrder { return 100; }

+ (UIViewController *)makeViewController {
    return [[GrowthViewController alloc] init];
}

// The tab the app opens on, both cold and on a resume after a real absence.
// See GLModule.h and GLModuleRegistry's +selectDefaultTabInTabBarController:.
+ (BOOL)moduleIsDefaultTab { return YES; }

@end
