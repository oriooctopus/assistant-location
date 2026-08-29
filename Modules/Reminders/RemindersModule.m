#import "RemindersModule.h"

#import "RemindersViewController.h"
#import "GLModuleRegistry.h"

@implementation RemindersModule

// Registers this module with GLModuleRegistry as the runtime loads this
// class, before main() runs. See GLModuleRegistry.m and MODULES.md — every
// GLModule conformer needs this exact +load or it silently never gets a tab.
+ (void)load {
    [GLModuleRegistry registerModule:self];
}

+ (NSString *)moduleTitle { return @"Reminders"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"bell.badge"]; }

+ (NSInteger)moduleOrder { return 100; }

+ (UIViewController *)makeViewController {
    return [[RemindersViewController alloc] init];
}

@end
