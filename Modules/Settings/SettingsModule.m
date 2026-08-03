#import "SettingsModule.h"

#import "SettingsViewController.h"
#import "GLModuleRegistry.h"

@implementation SettingsModule

// Registers this module with GLModuleRegistry as the runtime loads this
// class, before main() runs. See GLModuleRegistry.m and MODULES.md — every
// GLModule conformer needs this exact +load or it silently never gets a tab.
+ (void)load {
    [GLModuleRegistry registerModule:self];
}

+ (NSString *)moduleTitle { return @"Settings"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"gearshape.fill"]; }

+ (NSInteger)moduleOrder { return 500; }

+ (UIViewController *)makeViewController {
    UIStoryboard *main = [UIStoryboard storyboardWithName:@"Location" bundle:nil];
    return [main instantiateViewControllerWithIdentifier:@"SettingsViewController"];
}

@end
