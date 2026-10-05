#import "GoalTrackerModule.h"

#import "GoalTrackerViewController.h"
#import "GLModuleRegistry.h"

@implementation GoalTrackerModule

// Registers this module with GLModuleRegistry as the runtime loads this
// class, before main() runs. See GLModuleRegistry.m and MODULES.md — every
// GLModule conformer needs this exact +load or it silently never gets a tab.
+ (void)load {
    [GLModuleRegistry registerModule:self];
}

+ (NSString *)moduleTitle { return @"Continue?"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"gamecontroller.fill"]; }

+ (NSInteger)moduleOrder { return 705; }

+ (UIViewController *)makeViewController {
    return [[GoalTrackerViewController alloc] init];
}

@end
