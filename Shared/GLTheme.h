// Appearance mode + colour/type/metric tokens shared by every module and the
// web tabs (via GLWebModuleViewController). One source of truth for "what
// does this app look like" so radii/heights/insets stop drifting per module
// (today: radii 4/6/10, heights 44/48, insets 16/20/32 — see MODULES.md).

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Persisted appearance mode. GLThemeModeSystem tracks the device setting
/// (no override applied); Light/Dark force `overrideUserInterfaceStyle`.
typedef NS_ENUM(NSInteger, GLThemeMode) {
    GLThemeModeSystem = 0,
    GLThemeModeLight = 1,
    GLThemeModeDark = 2,
};

/// NSUserDefaults key for the persisted GLThemeMode (integer), following the
/// GL*DefaultsName convention used throughout GLManager.h.
static NSString *const GLThemeModeDefaultsName = @"GLThemeModeDefaults";

/// Posted after `+applyCurrentMode` changes the mode actually in effect.
/// Object is nil; no userInfo. GLWebModuleViewController observes this to
/// re-propagate the mode into its page.
static NSString *const GLThemeDidChangeNotification = @"GLThemeDidChangeNotification";

@interface GLTheme : NSObject

#pragma mark - Appearance mode

/// The persisted mode. Defaults to GLThemeModeSystem when nothing has been
/// saved yet.
+ (GLThemeMode)currentMode;

/// Persists `mode`, applies it to every connected UIWindowScene's window via
/// `overrideUserInterfaceStyle`, and posts GLThemeDidChangeNotification if the
/// effective mode actually changed.
+ (void)setCurrentMode:(GLThemeMode)mode;

/// Re-applies the persisted mode to every currently connected UIWindowScene.
/// Call at launch (a newly connected scene doesn't yet have the override) and
/// whenever a scene connects.
+ (void)applyCurrentMode;

/// "light" or "dark" — the mode actually in effect right now, resolving
/// GLThemeModeSystem against the key window's trait collection. Used as the
/// value for both the web-tab query param and the injected `data-theme`.
+ (NSString *)effectiveModeName;

#pragma mark - Colour tokens

+ (UIColor *)backgroundColor;
+ (UIColor *)surfaceColor;
+ (UIColor *)accentColor;
+ (UIColor *)destructiveColor;
+ (UIColor *)textPrimaryColor;
+ (UIColor *)textSecondaryColor;

#pragma mark - Type tokens

/// Built on `preferredFontForTextStyle:` so Dynamic Type actually works —
/// nothing in the app uses it today.
+ (UIFont *)titleFont;
+ (UIFont *)bodyFont;
+ (UIFont *)captionFont;
+ (UIFont *)monoDigitFont;
+ (UIFont *)buttonFont;

#pragma mark - Metric tokens

/// Spacing scale: 4, 8, 12, 16, 24, 32. Index into it rather than
/// hand-picking a constant per call site.
+ (CGFloat)spacingXXS;   // 4
+ (CGFloat)spacingXS;    // 8
+ (CGFloat)spacingS;     // 12
+ (CGFloat)spacingM;     // 16
+ (CGFloat)spacingL;     // 24
+ (CGFloat)spacingXL;    // 32

/// One corner radius (10 — matches Events/Todos/Upload's existing rounded
/// buttons; the smaller 4/6 radii elsewhere in Tracker are not shared-layer
/// concerns yet, per MODULES.md's deferred adoption scope).
+ (CGFloat)cornerRadius;

/// One control height (48 — matches Upload's chooseButton, the larger of the
/// two existing heights (44/48), since a bigger tap target never hurts and
/// this is the value new/adopted controls should converge on).
+ (CGFloat)controlHeight;

#pragma mark - Chrome appearance

/// Themes the shell chrome UIKit owns directly — the tab bar and every
/// navigation bar (including the system "More" list's) — from GLTheme's own
/// colour tokens: `UITabBarAppearance` background `surfaceColor`, selected
/// item tint `accentColor`, normal item tint `textSecondaryColor`;
/// `UINavigationBarAppearance` background `surfaceColor`, title/large-title
/// text `textPrimaryColor`, bar button tint `accentColor`. Sets the
/// `UITabBar`/`UINavigationBar` appearance proxies (so any bar created
/// afterwards picks it up) and also re-applies directly to any tab/nav bars
/// that already exist in a connected scene, since the appearance proxy has no
/// effect on views created before it's set. Colours come from
/// `+colorNamed:`-backed dynamic `UIColor`s, so they already re-resolve for
/// light/dark on their own — this does not need to be called again on a
/// `GLThemeDidChangeNotification`. Call once at launch, before the tab bar is
/// built.
+ (void)applyChromeAppearance;

@end

NS_ASSUME_NONNULL_END
