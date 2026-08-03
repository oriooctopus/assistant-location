#import "GLTheme.h"

// Colour token -> asset-catalog colour set name. Every one of these lives in
// GPSLogger/Assets.xcassets/<name>.colorset with light+dark variants.
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

@end
