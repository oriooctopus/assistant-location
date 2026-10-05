// Minimal host application for the ShellTests unit-test bundle. WKWebView
// cannot start a web content process inside a host-less xctest process (see
// SharedTests/GLWebKeyboardFocusTests.m), so tests that need a real web view
// run inside this app instead. It does nothing but keep a window up.
#import <UIKit/UIKit.h>

@interface ShellTestHostDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation ShellTestHostDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[UIViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([ShellTestHostDelegate class]));
    }
}
