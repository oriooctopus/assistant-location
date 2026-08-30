// Appearance mode + colour/type/metric tokens shared by every module and the
// web tabs (via GLWebModuleViewController). One source of truth for "what
// does this app look like" so radii/heights/insets stop drifting per module
// (today: radii 4/6/10, heights 44/48, insets 16/20/32 — see MODULES.md).

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

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

/// Posted by `+applyFetchedPalette:themeId:` whenever a freshly-fetched
/// palette is committed — a DIFFERENT event from GLThemeDidChangeNotification
/// above, which is reserved for light/dark/system MODE flips. A palette can
/// change (a new theme id picked in Settings, or the same id resolving
/// differently) without the mode changing at all. Object is nil; no
/// userInfo. GLWebModuleViewController observes this to push
/// `__glThemeChanged` into its page without a full reload — see
/// +applyFetchedPalette:themeId: for why it needed its own notification
/// rather than reusing GLThemeDidChangeNotification.
static NSString *const GLPaletteDidChangeNotification = @"GLPaletteDidChangeNotification";

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

/// "system"/"light"/"dark" — the string form of +currentMode. This is the
/// user's persisted PREFERENCE, which may be "system"; it is deliberately
/// distinct from +effectiveModeName below, which is always "light" or
/// "dark" (what's actually rendered right now, resolved against the
/// device). GLAppStateReporter reports both together specifically so a
/// report can show "system" resolving to a variant nobody expected, instead
/// of only restating the preference.
+ (NSString *)currentModeName;

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

/// The raw resolved palette leaf for right now — keys "bg"/"surface"/
/// "text"/"text-dim"/"accent"/"danger" (hex strings) plus an optional
/// "bg-gradient", exactly native-theme.json's own per-mode leaf shape, and
/// exactly what +backgroundColor/+accentColor/etc. above each pull one key
/// out of. Nil when no palette is cached (first-ever launch, offline) —
/// every caller (GLWebModuleViewController's boot-script/`__glThemeChanged`
/// payloads, GL_BOOT.palette in the frozen native<->web bridge protocol)
/// must treat nil as "no palette", not as an error. Same UITEST_NATIVE_PALETTE
/// short-circuit as every other colour accessor in this section.
+ (nullable NSDictionary<NSString *, id> *)currentPaletteColors;

#pragma mark - Background gradient

/// The current theme/variant's authored background gradient (native-
/// theme.json's `bg-gradient`: `{"angle": <CSS degrees>, "stops":
/// [{"color":"#rrggbb","position":0..1}, ...]}`, the same object the web
/// tabs paint with CSS `linear-gradient()`), or nil when the current
/// variant authors no gradient at all — that is the normal, common case
/// (most themes are flat), NOT an error, and every caller must treat a nil
/// return as "paint +backgroundColor instead" rather than skip painting
/// anything.
///
/// Sized and positioned for `UIScreen.mainScreen.bounds` — the same box
/// +backgroundColorAtVerticalFraction: measures against, and the box the
/// web tab's own CSS gradient is drawn across (a filled viewport). A
/// caller that hosts this layer in a view of a DIFFERENT size/aspect ratio
/// (or that resizes it later) must recompute `colors`/`locations` and, if
/// the aspect ratio changed, `startPoint`/`endPoint` too — CAGradientLayer
/// does not do either automatically. +applyBackgroundToView: below exists
/// specifically so most call sites never have to do that recomputation by
/// hand.
///
/// Callers own the returned layer (a fresh instance every call, never
/// cached/shared).
+ (nullable CAGradientLayer *)backgroundGradientLayer;

/// The gradient's colour at vertical position `fraction` down
/// `UIScreen.mainScreen.bounds` (0 = the screen's top edge, 1 = its bottom
/// edge), sampled along the CSS gradient LINE (not a naive "the box's
/// vertical axis IS the gradient" — an angled gradient's iso-colour lines
/// are perpendicular to the gradient direction, not horizontal) and
/// interpolated linearly between the bracketing stops in plain sRGB
/// component space, matching CSS's own default interpolation. Returns
/// `+backgroundColor` unchanged when the current variant has no gradient,
/// so every caller can use this unconditionally with no separate
/// has-a-gradient branch.
+ (UIColor *)backgroundColorAtVerticalFraction:(CGFloat)fraction;

/// Paints `view`'s background: installs the current gradient (as a
/// full-bleed subview pinned to all four edges, at index 0, whose own
/// backing layer IS a CAGradientLayer kept in sync with ITS bounds via a
/// `-layoutSubviews` override — never polling, never KVO-observing
/// `bounds`, which caused a scroll-feedback loop the one other time this
/// codebase tried it, since a `UIScrollView`'s `bounds.origin` literally
/// IS its `contentOffset`) when the current variant has one, or just sets
/// `view.backgroundColor` to the flat `+backgroundColor` when it doesn't.
/// Safe to call repeatedly (e.g. from a `-viewWillAppear:` that re-themes
/// on every appearance, matching GLMoreGridViewController's existing
/// pattern) — a previously-installed gradient subview is torn down first,
/// so a theme switch between a gradient and a flat variant never leaves a
/// stale layer behind.
+ (void)applyBackgroundToView:(UIView *)view;

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
/// (a JSON object with the six keys "bg"/"surface"/"text"/"text-dim"/
/// "accent"/"danger", each a "#rrggbb" string, PLUS an optional seventh
/// "bg-gradient" key — i.e. one leaf of native-theme.json verbatim, e.g.
/// native-theme.json's `dusk.light` — see +backgroundGradientLayer below
/// for that key's shape), this short-circuits entirely: no network call,
/// no NSUserDefaults read/write, every accessor above returns straight
/// from that dictionary regardless of +effectiveModeName or the selected
/// web theme. sim-test.yml never bakes GL_BAKED_HOST, so the real fetch
/// always fails there and every screenshot would show the OLD asset
/// colours with no way to prove this change actually re-themes the chrome
/// — this env var is CI's only way to inject a real palette for a
/// screenshot. The dictionary is passed through verbatim (no key
/// allowlist), so "bg-gradient" reaches +backgroundGradientLayer /
/// +backgroundColorAtVerticalFraction exactly as a real server fetch
/// would.
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

/// The currently selected web-theme id (e.g. "dusk"), or nil for Auto — see
/// GLThemeSelectedIdDefaultsName's doc comment. Hydrates from
/// NSUserDefaults on first call if nothing has fetched/loaded a palette yet
/// this process, so it's safe to call before +loadPalette's launch hydrate
/// runs. Exposed for GLAppStateReporter: the alternative was duplicating
/// GLCurrentPalette/GLCurrentSelectedThemeId's resolution inside a second
/// file, which is exactly the kind of drift that let a theming bug go
/// unnoticed against the wrong variant for days.
+ (nullable NSString *)selectedThemeId;

/// "server" if a palette fetch has succeeded this launch, "cache" if the
/// only palette available came from NSUserDefaults (a previous launch's
/// fetch, not re-confirmed this session), or "asset-fallback" if there is no
/// palette at all and every colour accessor above is falling through to the
/// static Assets.xcassets colours. Exists so GLAppStateReporter's report can
/// say honestly how stale/fresh the colours it's also reporting are, rather
/// than a bare hex dump that looks equally authoritative whether it's five
/// seconds or five days old.
+ (NSString *)paletteSource;

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
/// colour tokens: `UITabBarAppearance` background
/// `+backgroundColorAtVerticalFraction:` sampled at the tab bar's own
/// vertical position (near the SCREEN BOTTOM — see the fraction helpers in
/// GLTheme.m), selected item tint `accentColor`, normal item tint
/// `textSecondaryColor`; `UINavigationBarAppearance` background the same
/// helper sampled near the SCREEN TOP, title/large-title text
/// `textPrimaryColor`, bar button tint `accentColor`. Background is
/// deliberately NOT `surfaceColor` (a separate, flat token): the whole
/// point of this file's gradient support is that native chrome sitting at
/// the top/bottom edge of the screen must show the SAME colour the web
/// content immediately next to it is painting at that exact pixel row, and
/// a flat surface token can never do that once a theme authors a gradient
/// background. Sets the
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
