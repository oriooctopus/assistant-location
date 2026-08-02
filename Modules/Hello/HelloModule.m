#import "HelloModule.h"

#import "HelloViewController.h"

@implementation HelloModule

+ (NSString *)moduleTitle { return @"Hello"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"square.grid.2x2"]; }

+ (NSInteger)moduleOrder { return 400; }

+ (UIViewController *)makeViewController {
    return [[HelloViewController alloc] init];
}

@end
