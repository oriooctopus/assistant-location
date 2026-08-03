#import "TodosModule.h"

#import "TodosViewController.h"
#import "GLModuleRegistry.h"

@implementation TodosModule

// Registers this module with GLModuleRegistry as the runtime loads this
// class, before main() runs. See GLModuleRegistry.m and MODULES.md — every
// GLModule conformer needs this exact +load or it silently never gets a tab.
+ (void)load {
    [GLModuleRegistry registerModule:self];
}

+ (NSString *)moduleTitle { return @"Todos"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"checklist"]; }

+ (NSInteger)moduleOrder { return 200; }

+ (UIViewController *)makeViewController {
    return [[TodosViewController alloc] init];
}

@end
