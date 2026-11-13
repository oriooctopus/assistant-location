#import "ListsAppDelegate.h"

#import "ListsViewController.h"

@interface ListsAppDelegate ()
@property (nonatomic, strong) ListsViewController *viewController;
@end

@implementation ListsAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.viewController = [[ListsViewController alloc] init];
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = self.viewController;
    [self.window makeKeyAndVisible];
    return YES;
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    [self.viewController appDidForeground];
}

// lists://list/<id> is the widget's tap target (ListsWidget.swift widgetURL). On a cold launch iOS
// calls this right after didFinishLaunching, before the page has loaded; the view controller queues it.
- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
    if ([url.scheme isEqualToString:@"lists"] && [url.host isEqualToString:@"list"]) {
        NSString *listId = [url.path hasPrefix:@"/"] ? [url.path substringFromIndex:1] : url.path;
        if (listId.length) {
            [self.viewController openListWithId:listId];
            return YES;
        }
    }
    NSLog(@"[Lists] ignoring unrecognised URL %@", url);
    return NO;
}

@end
