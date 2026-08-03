// All of the location feature's app-shell-lifecycle behavior that used to
// live directly in AppDelegate.m / SceneDelegate.m: first-launch setup, the
// overland://setup URL handler, quick-action / Siri-shortcut handling, the
// build-diagnostic summary lines, and the background-location-delivery
// lifecycle hooks (foreground/background/resign-active/terminate).
//
// TrackerModule (TrackerModule.m) is the actual GLModule conformer; it just
// forwards each optional protocol method here so it stays readable.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface TrackerAppLifecycle : NSObject

+ (void)didFinishLaunching;
+ (BOOL)handleURL:(NSURL *)url;
+ (BOOL)handleShortcutItem:(UIApplicationShortcutItem *)item;
+ (NSString *)diagnosticSummary;

@end
