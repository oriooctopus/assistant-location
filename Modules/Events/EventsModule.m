#import "EventsModule.h"

#import "EventsViewController.h"

@implementation EventsModule

+ (NSString *)moduleTitle { return @"Events"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"calendar.badge.clock"]; }

+ (NSInteger)moduleOrder { return 400; }

+ (UIViewController *)makeViewController {
    return [[EventsViewController alloc] init];
}

@end
