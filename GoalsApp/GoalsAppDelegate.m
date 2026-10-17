#import "GoalsAppDelegate.h"

#import "GoalsViewController.h"

@implementation GoalsAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.backgroundColor = [UIColor colorWithRed:0x1c / 255.0 green:0x11 / 255.0 blue:0x30 / 255.0 alpha:1];
    self.window.rootViewController = [[GoalsViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end
