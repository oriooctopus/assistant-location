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

@end
