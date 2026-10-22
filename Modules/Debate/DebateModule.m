#import "DebateModule.h"

#import "DebateViewController.h"
#import "GLModuleRegistry.h"

@implementation DebateModule

// Registers this module with GLModuleRegistry as the runtime loads this
// class, before main() runs. See GLModuleRegistry.m and MODULES.md — every
// GLModule conformer needs this exact +load or it silently never gets a tab.
+ (void)load {
    [GLModuleRegistry registerModule:self];
}

+ (NSString *)moduleTitle { return @"Debate"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"scalemass"]; }

+ (NSInteger)moduleOrder { return 707; }

+ (UIViewController *)makeViewController {
    return [[DebateViewController alloc] init];
}

@end
