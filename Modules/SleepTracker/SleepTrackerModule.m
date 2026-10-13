#import "SleepTrackerModule.h"

#import "SleepTrackerViewController.h"
#import "GLModuleRegistry.h"

@implementation SleepTrackerModule

// Registers this module with GLModuleRegistry as the runtime loads this
// class, before main() runs. See GLModuleRegistry.m and MODULES.md — every
// GLModule conformer needs this exact +load or it silently never gets a tab.
+ (void)load {
    [GLModuleRegistry registerModule:self];
}

+ (NSString *)moduleTitle { return @"Sleep"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"bed.double"]; }

+ (NSInteger)moduleOrder { return 706; }

+ (UIViewController *)makeViewController {
    return [[SleepTrackerViewController alloc] init];
}

@end
