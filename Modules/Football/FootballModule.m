#import "FootballModule.h"

#import "FootballViewController.h"
#import "GLModuleRegistry.h"

@implementation FootballModule

// Registers this module with GLModuleRegistry as the runtime loads this
// class, before main() runs. See GLModuleRegistry.m and MODULES.md — every
// GLModule conformer needs this exact +load or it silently never gets a tab.
+ (void)load {
    [GLModuleRegistry registerModule:self];
}

+ (NSString *)moduleTitle { return @"Football"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"soccerball"]; }

+ (NSInteger)moduleOrder { return 350; }

+ (UIViewController *)makeViewController {
    return [[FootballViewController alloc] init];
}

@end
