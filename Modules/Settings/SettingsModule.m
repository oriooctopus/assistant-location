#import "SettingsModule.h"

#import "GLModuleRegistry.h"
#import "GLWebModuleViewController.h"

// SettingsViewController.h is deliberately NOT imported here any more --
// this module's tab is now the bundled "settings.html" web page (see
// Modules/WebPages/settings.html + Modules/WebBridge/GLWebBridge.m). The
// storyboard-backed SettingsViewController class stays in the tree, unused,
// per the web-conversion task's boundaries (deletion is a later commit).

@implementation SettingsModule

// Registers this module with GLModuleRegistry as the runtime loads this
// class, before main() runs. See GLModuleRegistry.m and MODULES.md — every
// GLModule conformer needs this exact +load or it silently never gets a tab.
+ (void)load {
    [GLModuleRegistry registerModule:self];
}

+ (NSString *)moduleTitle { return @"Settings"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"gearshape.fill"]; }

+ (NSInteger)moduleOrder { return 500; }

+ (UIViewController *)makeViewController {
    return [[GLWebModuleViewController alloc] initWithBundledPageNamed:@"settings.html"];
}

@end
