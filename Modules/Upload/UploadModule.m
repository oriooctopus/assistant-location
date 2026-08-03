#import "UploadModule.h"

#import "GLUploadViewController.h"

@implementation UploadModule

+ (NSString *)moduleTitle { return @"Upload"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"square.and.arrow.up"]; }

+ (NSInteger)moduleOrder { return 600; }

+ (UIViewController *)makeViewController {
    return [[GLUploadViewController alloc] init];
}

@end
