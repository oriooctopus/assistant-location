#import "ListenModule.h"

#import "GLModuleRegistry.h"
#import "ListenViewController.h"

@implementation ListenModule

// Registers this module with GLModuleRegistry as the runtime loads this
// class, before main() runs. See GLModuleRegistry.m and MODULES.md — every
// GLModule conformer needs this exact +load or it silently never gets a tab.
+ (void)load {
    [GLModuleRegistry registerModule:self];
}

+ (NSString *)moduleTitle { return @"Listen"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"headphones"]; }

+ (NSInteger)moduleOrder { return 696; }

+ (UIViewController *)makeViewController {
    return [[ListenViewController alloc] init];
}

@end
