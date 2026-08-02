#import "TrackerModule.h"

#import "TrackingViewController.h"

@implementation TrackerModule

+ (NSString *)moduleTitle { return @"Tracker"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"location.fill"]; }

+ (NSInteger)moduleOrder { return 100; }

// TrackingViewController is laid out in Main.storyboard and wired to ~20
// IBOutlets, so it is instantiated from the storyboard rather than built in
// code. The storyboard no longer decides where the tab goes — this does.
+ (UIViewController *)makeViewController {
    UIStoryboard *main = [UIStoryboard storyboardWithName:@"Main" bundle:nil];
    return [main instantiateViewControllerWithIdentifier:@"TrackingViewController"];
}

@end
