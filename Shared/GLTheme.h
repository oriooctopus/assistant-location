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

/// NSUserDefaults key for the cached native-theme.json palette (all theme
/// ids, JSON-serialized) — see +loadPalette. Hydrated synchronously at next
/// launch so cold-launch chrome doesn't flash asset colours before the
/// network re-fetch returns.
static NSString *const GLThemePaletteDefaultsName = @"GLThemePaletteDefaults";

/// NSUserDefaults key for the cached selected web-theme id (a String; ABSENT
/// means Auto, matching ~/.config/assistant/ui-prefs.json's own
/// `{"theme": null}` = Auto convention — see +loadPalette).
static NSString *const GLThemeSelectedIdDefaultsName = @"GLThemeSelectedIdDefaults";

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

/// Every accessor below returns the resolved colour from the fetched
/// design-tokens palette (design-tokens/build.mjs's native-theme.json,
/// served by events/server.py at :8304/native-theme.json) when one is
/// loaded, falling back to the static `App/Assets.xcassets` colorset
/// (`GLBackgroundColor` etc.) otherwise — the offline/unfetched/CI-without-
/// GL_BAKED_HOST case. See +loadPalette for when/how the palette is
/// fetched and cached.
+ (UIColor *)backgroundColor;
+ (UIColor *)surfaceColor;
+ (UIColor *)accentColor;
+ (UIColor *)destructiveColor;
+ (UIColor *)textPrimaryColor;
+ (UIColor *)textSecondaryColor;

/// Hydrates the colour-token palette synchronously from whatever was cached
/// last session (NSUserDefaults — see GLThemePaletteDefaultsName), then
/// kicks off an async re-fetch from the events server (:8304) to pick up
/// anything picked in Settings since. Call once at launch, BEFORE
/// +applyChromeAppearance, same ordering AppDelegate already uses for
/// +applyCurrentMode -> +applyChromeAppearance: the synchronous hydrate is
/// what makes a cold launch paint the CORRECT theme on the very first
/// frame instead of flashing the asset-catalog colours then jumping once
/// the network call returns.
///
/// Test hook: if the `UITEST_NATIVE_PALETTE` environment variable is set
/// (a JSON object with exactly the six keys "bg"/"surface"/"text"/
/// "text-dim"/"accent"/"danger", each a "#rrggbb" string — i.e. one leaf
/// of native-theme.json, e.g. native-theme.json's `dusk.dark`), this
/// short-circuits entirely: no network call, no NSUserDefaults read/write,
/// every accessor above returns straight from that dictionary regardless
/// of +effectiveModeName or the selected web theme. sim-test.yml never
/// bakes GL_BAKED_HOST, so the real fetch always fails there and every
/// screenshot would show the OLD asset colours with no way to prove this
/// change actually re-themes the chrome — this env var is CI's only way to
/// inject a real palette for a screenshot.
+ (void)loadPalette;

/// Re-fetches the palette right now, independent of launch. Call this after
/// a PUT to /api/theme succeeds (SettingsViewController.m's theme picker)
/// so the native chrome re-themes immediately instead of waiting for the
/// next cold launch's +loadPalette hydrate — otherwise picking a theme only
/// ever re-themed the web tabs (which independently re-fetch
/// /api/theme themselves) and left the tab bar/nav bars showing the
/// PREVIOUS palette until the app was killed and reopened. No-ops (network
/// call still fires but its result is discarded) under the
/// UITEST_NATIVE_PALETTE test hook, same as +loadPalette.
+ (void)refreshPaletteFromServer;

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
/// effect on views created before it's set. Call once at launch, before the
/// tab bar is built.
///
/// CORRECTNESS NOTE (palette era): when no palette is loaded, every colour
/// above comes from `+colorNamed:`-backed DYNAMIC `UIColor`s, which
/// re-resolve for light/dark on their own — that used to mean this method
/// never needed re-calling on a mode change. That stopped being true once
/// +loadPalette exists: a loaded palette's colours are plain STATIC
/// `UIColor`s baked from hex at the moment this method runs, so a mode
/// flip (or a freshly-arrived palette) produces a DIFFERENT static colour
/// that nothing re-resolves automatically — this method has to be called
/// again, which is exactly what GLTheme.m's own `+load` does by observing
/// `GLThemeDidChangeNotification`, and what +loadPalette's fetch completion
/// does directly. Don't remove that observer thinking it's now redundant
/// with dynamic-colour auto-resolution; it isn't, once a palette is loaded.
+ (void)applyChromeAppearance;

@end

NS_ASSUME_NONNULL_END
