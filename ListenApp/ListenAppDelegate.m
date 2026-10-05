#import "ListenAppDelegate.h"

#import "ListenViewController.h"

// No scene manifest: a single-window app, so the app delegate owns the window.
@implementation ListenAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[ListenViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end
