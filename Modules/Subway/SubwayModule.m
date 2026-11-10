#import "SubwayModule.h"

#import "GLModuleRegistry.h"
#import "Overland-Swift.h" // GLSubwayScreen (JournalControl/SubwayScreenView.swift)

@implementation SubwayModule

// Registers this module with GLModuleRegistry as the runtime loads this class, before main() runs. See
// GLModuleRegistry.m and MODULES.md — every GLModule conformer needs this exact +load or it silently never gets a tab.
+ (void)load {
    [GLModuleRegistry registerModule:self];
}

+ (NSString *)moduleTitle { return @"Subway"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"tram.fill"]; }

// After Debate (707); the More grid's DEFAULT_ORDER in WebPages/more.html lists it last to match.
+ (NSInteger)moduleOrder { return 730; }

+ (UIViewController *)makeViewController {
    return [GLSubwayScreen makeViewController];
}

#pragma mark - GLModule optional hooks

// The home-screen widget and the Live Activity both open overland://subway (widgetURL in JournalControl/SubwayWidget.swift).
+ (BOOL)moduleHandleURL:(NSURL *)url {
    if (![url.scheme isEqualToString:@"overland"] || ![url.host isEqualToString:@"subway"]) return NO;
    return [GLModuleRegistry showModuleWithIdentifier:@"GLModule.SubwayModule"];
}

@end
