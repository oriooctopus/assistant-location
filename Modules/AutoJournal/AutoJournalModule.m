#import "AutoJournalModule.h"

#import "AutoJournalViewController.h"
#import "GLModuleRegistry.h"

@implementation AutoJournalModule

// Registers this module with GLModuleRegistry as the runtime loads this
// class, before main() runs. See GLModuleRegistry.m and MODULES.md — every
// GLModule conformer needs this exact +load or it silently never gets a tab.
+ (void)load {
    [GLModuleRegistry registerModule:self];
}

+ (NSString *)moduleTitle { return @"Journal"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"mic.circle.fill"]; }

+ (NSInteger)moduleOrder { return 100; }

+ (UIViewController *)makeViewController {
    return [[AutoJournalViewController alloc] init];
}

@end
