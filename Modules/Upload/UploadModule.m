#import "UploadModule.h"

#import "GLUploadViewController.h"
#import "GLModuleRegistry.h"

@implementation UploadModule

// Registers this module with GLModuleRegistry as the runtime loads this
// class, before main() runs. See GLModuleRegistry.m and MODULES.md — every
// GLModule conformer needs this exact +load or it silently never gets a tab.
+ (void)load {
    [GLModuleRegistry registerModule:self];
}

+ (NSString *)moduleTitle { return @"Upload"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"square.and.arrow.up"]; }

+ (NSInteger)moduleOrder { return 600; }

+ (UIViewController *)makeViewController {
    return [[GLUploadViewController alloc] init];
}

@end
