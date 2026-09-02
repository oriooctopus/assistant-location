#import "SettingsModule.h"

#import "GLModuleRegistry.h"
#import "GLWebModuleViewController.h"

// SettingsViewController.h is deliberately NOT imported here any more --
// this module's tab is now the MANAGED "settings.html" web page (see
// Modules/WebPages/settings.html + Modules/WebBridge/GLWebBridge.m +
// Shared/GLWebPageCache.h — managed rather than merely bundled as of the
// web-page asset-update task, so a server-side edit reaches this tab
// through the normal deploy instead of needing a full OTA rebuild). The
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

// 300 (was 500): first of the five More-grid overflow modules, so it lands
// in the grid's row-1/tile-1 slot -- the one more.html's ".gl-tile:first-
// child" CSS renders alone, centred on its own row (Oliver's pick: Settings
// is what he reaches for least, so it goes to the worst thumb-reach spot).
// See MODULES.md's order list and more.html's DEFAULT_ORDER for the full
// sequence this must stay in sync with.
+ (NSInteger)moduleOrder { return 300; }

+ (UIViewController *)makeViewController {
    return [[GLWebModuleViewController alloc] initWithManagedPageNamed:@"settings.html"];
}

@end
