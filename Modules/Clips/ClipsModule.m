#import "ClipsModule.h"

#import "ClipsCatalog.h"
#import "ClipsViewController.h"
#import "GLModuleRegistry.h"

// The one tab instance, so a deep link can reach it (makeViewController runs
// once, from the registry, before any URL is routed).
static __weak ClipsViewController *clipsController;

@implementation ClipsModule

+ (void)load {
    [GLModuleRegistry registerModule:self];
}

+ (NSString *)moduleTitle { return @"Clips"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"waveform"]; }

+ (NSInteger)moduleOrder { return 710; }

+ (UIViewController *)makeViewController {
    ClipsViewController *vc = [[ClipsViewController alloc] init];
    clipsController = vc;
    return vc;
}

// overland://clips/<id>: select the tab and play that clip. The registry
// builds every controller before routing any URL, so this works on a cold
// launch as well as a warm one.
+ (BOOL)moduleHandleURL:(NSURL *)url {
    NSString *clipID = [ClipsCatalog clipIDFromURL:url];
    if (!clipID) return NO;
    [GLModuleRegistry showModuleWithIdentifier:@"GLModule.ClipsModule"];
    [clipsController playClipWithID:clipID];
    return YES;
}

@end
