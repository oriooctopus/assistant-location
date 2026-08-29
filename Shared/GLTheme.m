#import "GLTheme.h"

// Colour token -> asset-catalog colour set name. Every one of these lives in
// App/Assets.xcassets/<name>.colorset with light+dark variants.
static NSString *const kGLBackgroundColorName = @"GLBackgroundColor";
static NSString *const kGLSurfaceColorName = @"GLSurfaceColor";
static NSString *const kGLAccentColorName = @"GLAccentColor";
static NSString *const kGLDestructiveColorName = @"GLDestructiveColor";
static NSString *const kGLTextPrimaryColorName = @"GLTextPrimaryColor";
static NSString *const kGLTextSecondaryColorName = @"GLTextSecondaryColor";

@implementation GLTheme

#pragma mark - Appearance mode

+ (GLThemeMode)currentMode {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults objectForKey:GLThemeModeDefaultsName]) {
        return GLThemeModeSystem;
    }
    return (GLThemeMode)[defaults integerForKey:GLThemeModeDefaultsName];
}

+ (void)setCurrentMode:(GLThemeMode)mode {
    GLThemeMode previous = [self currentMode];
    [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:GLThemeModeDefaultsName];
    [self applyCurrentMode];
    if (mode != previous) {
        [[NSNotificationCenter defaultCenter] postNotificationName:GLThemeDidChangeNotification
                                                              object:nil];
    }
}

+ (UIUserInterfaceStyle)styleForMode:(GLThemeMode)mode {
    switch (mode) {
        case GLThemeModeLight: return UIUserInterfaceStyleLight;
        case GLThemeModeDark: return UIUserInterfaceStyleDark;
        case GLThemeModeSystem: return UIUserInterfaceStyleUnspecified;
    }
    [NSException raise:NSInternalInconsistencyException format:@"unhandled GLThemeMode %ld", (long)mode];
}

+ (void)applyCurrentMode {
    UIUserInterfaceStyle style = [self styleForMode:[self currentMode]];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            window.overrideUserInterfaceStyle = style;
        }
    }
}

+ (NSString *)effectiveModeName {
    GLThemeMode mode = [self currentMode];
    if (mode == GLThemeModeLight) return @"light";
    if (mode == GLThemeModeDark) return @"dark";

    UIUserInterfaceStyle resolved = UIUserInterfaceStyleLight;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        UIWindow *window = windowScene.windows.firstObject;
        if (window) {
            resolved = window.traitCollection.userInterfaceStyle;
            break;
        }
    }
    return resolved == UIUserInterfaceStyleDark ? @"dark" : @"light";
}

#pragma mark - Colour tokens

+ (UIColor *)backgroundColor {
    return [UIColor colorNamed:kGLBackgroundColorName];
}

+ (UIColor *)surfaceColor {
    return [UIColor colorNamed:kGLSurfaceColorName];
}

+ (UIColor *)accentColor {
    return [UIColor colorNamed:kGLAccentColorName];
}

+ (UIColor *)destructiveColor {
    return [UIColor colorNamed:kGLDestructiveColorName];
}

+ (UIColor *)textPrimaryColor {
    return [UIColor colorNamed:kGLTextPrimaryColorName];
}

+ (UIColor *)textSecondaryColor {
    return [UIColor colorNamed:kGLTextSecondaryColorName];
}

#pragma mark - Type tokens

+ (UIFont *)titleFont {
    return [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
}

+ (UIFont *)bodyFont {
    return [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
}

+ (UIFont *)captionFont {
    return [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
}

+ (UIFont *)monoDigitFont {
    UIFontDescriptor *descriptor =
        [UIFontDescriptor preferredFontDescriptorWithTextStyle:UIFontTextStyleTitle1];
    return [UIFont monospacedDigitSystemFontOfSize:descriptor.pointSize weight:UIFontWeightRegular];
}

+ (UIFont *)buttonFont {
    UIFontDescriptor *descriptor =
        [UIFontDescriptor preferredFontDescriptorWithTextStyle:UIFontTextStyleBody];
    UIFontDescriptor *bold =
        [descriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold];
    return [UIFont fontWithDescriptor:bold ?: descriptor size:0];
}

#pragma mark - Metric tokens

+ (CGFloat)spacingXXS { return 4; }
+ (CGFloat)spacingXS { return 8; }
+ (CGFloat)spacingS { return 12; }
+ (CGFloat)spacingM { return 16; }
+ (CGFloat)spacingL { return 24; }
+ (CGFloat)spacingXL { return 32; }

+ (CGFloat)cornerRadius { return 10; }

+ (CGFloat)controlHeight { return 48; }

#pragma mark - Chrome appearance

+ (UITabBarAppearance *)makeTabBarAppearance {
    UITabBarAppearance *appearance = [[UITabBarAppearance alloc] init];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = [self surfaceColor];

    // All three layouts, not just stacked: iPhone portrait uses stacked, but
    // landscape switches to compactInline, and an unstyled layout there would
    // show system-blue items on the themed bar.
    for (UITabBarItemAppearance *item in @[appearance.stackedLayoutAppearance,
                                           appearance.inlineLayoutAppearance,
                                           appearance.compactInlineLayoutAppearance]) {
        item.selected.iconColor = [self accentColor];
        item.selected.titleTextAttributes = @{ NSForegroundColorAttributeName: [self accentColor] };
        item.normal.iconColor = [self textSecondaryColor];
        item.normal.titleTextAttributes = @{ NSForegroundColorAttributeName: [self textSecondaryColor] };
    }

    return appearance;
}

+ (UINavigationBarAppearance *)makeNavigationBarAppearance {
    UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = [self surfaceColor];
    appearance.titleTextAttributes = @{ NSForegroundColorAttributeName: [self textPrimaryColor] };
    appearance.largeTitleTextAttributes = @{ NSForegroundColorAttributeName: [self textPrimaryColor] };
    return appearance;
}

+ (void)applyChromeAppearance {
    UITabBarAppearance *tabBarAppearance = [self makeTabBarAppearance];
    [UITabBar appearance].standardAppearance = tabBarAppearance;
    [UITabBar appearance].scrollEdgeAppearance = tabBarAppearance;

    UINavigationBarAppearance *navBarAppearance = [self makeNavigationBarAppearance];
    [UINavigationBar appearance].standardAppearance = navBarAppearance;
    [UINavigationBar appearance].compactAppearance = navBarAppearance;
    [UINavigationBar appearance].scrollEdgeAppearance = navBarAppearance;
    // Bar button tint isn't part of UINavigationBarAppearance — it cascades
    // from the bar's own `tintColor`, same as `overrideUserInterfaceStyle`
    // below being a UIWindow property rather than an appearance-object one.
    [UINavigationBar appearance].tintColor = [self accentColor];

    // The two proxy assignments above only affect bars created after this
    // call. Re-apply directly to whatever the app's actual shape already has
    // live right now: the root tab bar controller's own tab bar, the "More"
    // list's navigation bar, and any module that wraps its own root in a
    // UINavigationController (e.g. AutoJournal).
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            UIViewController *root = window.rootViewController;
            if (![root isKindOfClass:[UITabBarController class]]) continue;
            UITabBarController *tabs = (UITabBarController *)root;

            tabs.tabBar.standardAppearance = tabBarAppearance;
            tabs.tabBar.scrollEdgeAppearance = tabBarAppearance;

            NSMutableArray<UINavigationController *> *navControllers = [NSMutableArray array];
            for (UIViewController *child in tabs.viewControllers) {
                if ([child isKindOfClass:[UINavigationController class]]) {
                    [navControllers addObject:(UINavigationController *)child];
                }
            }
            [navControllers addObject:tabs.moreNavigationController];

            for (UINavigationController *nav in navControllers) {
                nav.navigationBar.standardAppearance = navBarAppearance;
                nav.navigationBar.compactAppearance = navBarAppearance;
                nav.navigationBar.scrollEdgeAppearance = navBarAppearance;
                nav.navigationBar.tintColor = [self accentColor];
            }
        }
    }
}

@end
