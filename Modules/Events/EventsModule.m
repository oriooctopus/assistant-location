#import "EventsModule.h"

#import "EventsViewController.h"
#import "GLModuleRegistry.h"

@implementation EventsModule

// Registers this module with GLModuleRegistry as the runtime loads this
// class, before main() runs. See GLModuleRegistry.m and MODULES.md — every
// GLModule conformer needs this exact +load or it silently never gets a tab.
+ (void)load {
    [GLModuleRegistry registerModule:self];
}

+ (NSString *)moduleTitle { return @"Events"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"calendar.badge.clock"]; }

+ (NSInteger)moduleOrder { return 650; }

+ (UIViewController *)makeViewController {
    return [[EventsViewController alloc] init];
}

@end
