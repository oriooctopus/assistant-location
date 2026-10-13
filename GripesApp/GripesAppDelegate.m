#import "GripesAppDelegate.h"

#import "BakedConfig.h"
#import "GripesStore.h"
#import "GripesViewController.h"

@interface GripesAppDelegate ()
@property (nonatomic, strong) GripesStore *store;
@property (nonatomic, strong) GripesViewController *viewController;
@property (nonatomic, assign) NSUInteger syncTicket; // latest scheduled sync wins; earlier timers no-op
@end

@implementation GripesAppDelegate

- (NSURL *)baseURL {
    return [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:8326", GL_BAKED_HOST]];
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask
                                                  appropriateForURL:nil create:YES error:NULL];
    self.store = [[GripesStore alloc] initWithDirectory:support];
    self.viewController = [[GripesViewController alloc] initWithStore:self.store];
    __weak typeof(self) weakSelf = self;
    self.viewController.requestSync = ^(NSTimeInterval delay) { [weakSelf syncAfter:delay]; };
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = self.viewController;
    [self.window makeKeyAndVisible];
#if !DEBUG
    // The screenshot builds (DEBUG) must not talk to the box.
    [self syncAfter:0];
#endif
    return YES;
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
#if !DEBUG
    [self syncAfter:0];
#endif
}

// Silent, best-effort: a delay lets the page's Undo beat the push (the server has no delete).
- (void)syncAfter:(NSTimeInterval)delay {
#if !DEBUG
    NSUInteger ticket = ++self.syncTicket;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (ticket != self.syncTicket) return;
        [self.store syncWithBaseURL:self.baseURL token:GL_BAKED_TOKEN session:NSURLSession.sharedSession completion:^(BOOL changed) {
            if (changed) [self.viewController entriesChanged];
        }];
    });
#endif
}

// gripes://log opens the logging view (the Shortcuts "Open App"/URL action target).
- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
    if ([url.scheme isEqualToString:@"gripes"] && [url.host isEqualToString:@"log"]) {
        [self.viewController openLog];
        return YES;
    }
    NSLog(@"[Gripes] ignoring unrecognised URL %@", url);
    return NO;
}

@end
