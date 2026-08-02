#import "PingModule.h"

#import "PingViewController.h"

@implementation PingModule

+ (NSString *)moduleTitle { return @"Ping"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"square.grid.2x2"]; }

+ (NSInteger)moduleOrder { return 400; }

+ (UIViewController *)makeViewController {
    return [[PingViewController alloc] init];
}

@end
