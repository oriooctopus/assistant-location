#import "SettingsModule.h"

#import "SettingsViewController.h"

@implementation SettingsModule

+ (NSString *)moduleTitle { return @"Settings"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"gearshape.fill"]; }

+ (NSInteger)moduleOrder { return 200; }

+ (UIViewController *)makeViewController {
    UIStoryboard *main = [UIStoryboard storyboardWithName:@"Main" bundle:nil];
    return [main instantiateViewControllerWithIdentifier:@"SettingsViewController"];
}

@end
