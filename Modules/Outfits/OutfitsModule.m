#import "OutfitsModule.h"

#import "OutfitsViewController.h"
#import "GLModuleRegistry.h"

@implementation OutfitsModule

// Registers this module with GLModuleRegistry as the runtime loads this
// class, before main() runs. See GLModuleRegistry.m and MODULES.md — every
// GLModule conformer needs this exact +load or it silently never gets a tab.
+ (void)load {
    [GLModuleRegistry registerModule:self];
}

+ (NSString *)moduleTitle { return @"Outfits"; }

// "tshirt" exists from iOS 15; the app target's deployment target is 18.0.
+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"tshirt"]; }

// Free slot between Sessions (660) and Questions/Facebook (680).
+ (NSInteger)moduleOrder { return 670; }

+ (UIViewController *)makeViewController {
    return [[OutfitsViewController alloc] init];
}

// CI hook (sim-test): UITEST_REPORT_OUTFITS=1 makes the app log, a while after
// launch, whether the Outfits page is on screen and the web view's real
// location.href, read from the page itself.
+ (void)moduleDidFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    if ([[NSProcessInfo processInfo] environment][@"UITEST_REPORT_OUTFITS"] == nil) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        OutfitsViewController *page = [OutfitsViewController current];
        BOOL onScreen = page.viewIfLoaded.window != nil;
        [page evaluateTestJavaScript:@"location.href" completionHandler:^(id result, NSError *error) {
            NSLog(@"UITEST_OUTFITS_REPORT onScreen=%d href=%@ error=%@", onScreen, result, error);
        }];
    });
}

// overland://outfits[/<path>] (Picnic's "Review now"): selects the Outfits
// tab and, with a path, navigates its web view to <base>/#/<path>. The path
// is taken from the raw URL string, not NSURL.path, so a percent-encoded
// "%2F" inside an id reaches the web app still encoded. Cold launches reach
// this through SceneDelegate's connectionOptions routing, warm ones through
// -scene:openURLContexts:.
+ (BOOL)moduleHandleURL:(NSURL *)url {
    if (![url.scheme isEqualToString:@"overland"]) return NO;
    if (![url.host isEqualToString:@"outfits"]) return NO;

    NSString *raw = url.absoluteString;
    NSString *prefix = @"overland://outfits";
    NSString *rest = [raw substringFromIndex:prefix.length];
    NSString *path = nil;
    if ([rest hasPrefix:@"/"] && rest.length > 1) path = [rest substringFromIndex:1];

    OutfitsViewController *page = [OutfitsViewController current];
    if (page == nil) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"overland://outfits arrived before OutfitsViewController was built"];
    }
    // Pending path first, so a first load triggered by showing the tab already
    // carries the fragment; -openPath: reloads only if the page is already up.
    if (path != nil) [page openPath:path];
    return [GLModuleRegistry showModuleWithIdentifier:@"GLModule.OutfitsModule"];
}

@end
