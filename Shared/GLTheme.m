#import "GLTheme.h"
#import "BakedConfig.h"
#import "GLLog.h"

// Colour token -> asset-catalog colour set name. Every one of these lives in
// App/Assets.xcassets/<name>.colorset with light+dark variants.
static NSString *const kGLBackgroundColorName = @"GLBackgroundColor";
static NSString *const kGLSurfaceColorName = @"GLSurfaceColor";
static NSString *const kGLAccentColorName = @"GLAccentColor";
static NSString *const kGLDestructiveColorName = @"GLDestructiveColor";
static NSString *const kGLTextPrimaryColorName = @"GLTextPrimaryColor";
static NSString *const kGLTextSecondaryColorName = @"GLTextSecondaryColor";

#pragma mark - Palette fetch/cache plumbing

// The palette lives on the same events server the web tabs and Settings'
// theme picker already use (Modules/Settings/SettingsViewController.m,
// Modules/Events/EventsViewController.m) — this module owns no server of
// its own. Duplicated constant (not shared with SettingsViewController.m)
// because that constant is `static` to its own file; both name the exact
// same port for the exact same reason, see ~/.claude/rules/ports.md.
static NSInteger const kGLThemeServerPort = 8304;

// Builds `http://GL_BAKED_HOST:8304<path>` directly, the SAME way
// SettingsViewController.m's themeServerURLWithPath: does, and for the same
// reason: GLEndpoints.h's GLEndpointURL() *raises* when GL_BAKED_HOST is
// unbaked, which is true for every sim-test CI build. Building the string
// directly instead lets an unbaked/unreachable host fail through
// NSURLSession's ordinary error path (host not found) so the palette
// section degrades to "keep whatever's cached/asset colours" instead of
// crashing the app before a single frame renders.
static NSURL *GLThemeServerURLWithPath(NSString *path) {
    NSString *urlString = [NSString stringWithFormat:@"http://%@:%ld%@", GL_BAKED_HOST, (long)kGLThemeServerPort, path];
    return [NSURL URLWithString:urlString];
}

// Shared success/parse gate for both endpoints this file fetches (mirrors
// SettingsViewController.m's JSONFromResponse:expectedClass: — duplicated
// rather than shared because that method is an instance method on a view
// controller and this is a static utility class with no instance).
static id GLThemeJSONFromResponse(NSURLResponse *response, NSData *data, NSError *error, Class expectedClass) {
    if (error || data.length == 0) return nil;
    NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
    if (status < 200 || status > 299) return nil;
    NSError *jsonError = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (jsonError || ![parsed isKindOfClass:expectedClass]) return nil;
    return parsed;
}

// In-memory cache of the fetched native-theme.json palette (every theme id
// -> {light: {...6 colours...}, dark: {...}}) plus the currently-selected
// web-theme id (nil = Auto). Plain static globals, not an ivar/property on
// GLTheme (a class with no instances) — every read/write here happens on
// the main thread (every network completion in this file dispatches back
// to it before touching these, same pattern as the rest of the app), so no
// lock is needed.
static NSDictionary *GLCurrentPalette = nil;
static NSString *GLCurrentSelectedThemeId = nil;
static BOOL GLPaletteHydratedFromDefaults = NO;

// Lazily loads GLCurrentPalette/GLCurrentSelectedThemeId from NSUserDefaults
// exactly once per process. This is what makes the very FIRST call to e.g.
// +backgroundColor (from AppDelegate's +applyChromeAppearance, which runs
// synchronously before any scene/tab bar exists) already reflect last
// session's fetched palette — the alternative (waiting for +loadPalette's
// async re-fetch to land) is precisely the cold-launch "asset blue flashes
// before purple" bug this whole task exists to avoid.
static void GLHydratePaletteFromDefaultsIfNeeded(void) {
    if (GLPaletteHydratedFromDefaults) return;
    GLPaletteHydratedFromDefaults = YES;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSData *data = [defaults dataForKey:GLThemePaletteDefaultsName];
    if (data) {
        NSError *error = nil;
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (!error && [parsed isKindOfClass:[NSDictionary class]]) {
            GLCurrentPalette = parsed;
        }
    }
    GLCurrentSelectedThemeId = [defaults stringForKey:GLThemeSelectedIdDefaultsName];
}

// CI test hook (see GLTheme.h's +loadPalette doc comment for the exact env
// var / JSON shape). Parsed once per process via dispatch_once, same
// pattern as GLModuleRegistry's GLRegisteredModules() — env vars can't
// change mid-process, so there is nothing to invalidate.
static NSDictionary *GLUITestInjectedPalette(void) {
    static NSDictionary *injected;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *json = [[NSProcessInfo processInfo] environment][@"UITEST_NATIVE_PALETTE"];
        if (json.length == 0) return;
        NSError *error = nil;
        id parsed = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                                                      options:0
                                                        error:&error];
        if (error || ![parsed isKindOfClass:[NSDictionary class]]) {
            NSLog(@"GLTheme: UITEST_NATIVE_PALETTE is not a valid JSON object: %@", error.localizedDescription ?: @"(not an object)");
            return;
        }
        injected = parsed;
    });
    return injected;
}

// Parses design-tokens/build.mjs's guaranteed-opaque "#rrggbb" output (see
// that file's buildNativePalette/resolveNativeColor header comments) into a
// UIColor. Returns nil for anything else — malformed cached JSON (a stale
// format from a future edit of native-theme.json's shape) degrades to the
// asset-catalog fallback rather than drawing black/garbage.
static UIColor *GLColorFromHexString(NSString *hex) {
    if (![hex isKindOfClass:[NSString class]] || hex.length != 7 || [hex characterAtIndex:0] != '#') {
        return nil;
    }
    NSScanner *scanner = [NSScanner scannerWithString:[hex substringFromIndex:1]];
    unsigned int rgb = 0;
    if (![scanner scanHexInt:&rgb] || !scanner.isAtEnd) return nil;
    CGFloat r = ((rgb >> 16) & 0xFF) / 255.0;
    CGFloat g = ((rgb >> 8) & 0xFF) / 255.0;
    CGFloat b = (rgb & 0xFF) / 255.0;
    return [UIColor colorWithRed:r green:g blue:b alpha:1.0];
}

@implementation GLTheme

// Registers the re-apply-on-mode-change fix (see GLTheme.h's
// +applyChromeAppearance "CORRECTNESS NOTE"): a loaded palette's colours are
// static, so a mode flip needs the tab/nav bar appearance objects rebuilt
// from scratch, not just a trait-collection re-resolve. `self` here is the
// Class object itself (a valid NSNotificationCenter observer) and
// +load runs once at image-load time, well before AppDelegate's
// didFinishLaunchingWithOptions ever posts the notification.
+ (void)load {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(handleThemeDidChangeNotification:)
                                                  name:GLThemeDidChangeNotification
                                                object:nil];
}

+ (void)handleThemeDidChangeNotification:(NSNotification *)notification {
    [self applyChromeAppearance];
}

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

// Resolves the currently-loaded palette's 6-colour dictionary, or nil if
// none is available yet (never fetched, fetch failed, and nothing cached
// from a previous launch). A UITEST injection always wins outright,
// ignoring the selected theme id / effective mode entirely — see
// GLUITestInjectedPalette's header comment.
//
// Auto (GLCurrentSelectedThemeId == nil) resolves `themeKey` to the
// effective MODE NAME itself ("light"/"dark") rather than looking anything
// up first: native-theme.json's own "light"/"dark" entries are exactly
// tokens.json's un-family'd base themes (the same ones the web's bare
// `:root`/`@media(prefers-color-scheme)` fallback paints when no
// `data-theme` is set), so `palette["light"]["light"]` /
// `palette["dark"]["dark"]` IS the correct Auto resolution for each mode —
// no separate "auto" case to special-render.
+ (nullable NSDictionary<NSString *, NSString *> *)currentPaletteColors {
    NSDictionary *injected = GLUITestInjectedPalette();
    if (injected) return injected;

    GLHydratePaletteFromDefaultsIfNeeded();
    if (!GLCurrentPalette) return nil;

    NSString *mode = [self effectiveModeName];
    NSString *themeKey = GLCurrentSelectedThemeId ?: mode;
    NSDictionary *variants = GLCurrentPalette[themeKey];
    if (![variants isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *colors = variants[mode];
    return [colors isKindOfClass:[NSDictionary class]] ? colors : nil;
}

+ (nullable UIColor *)paletteColorForKey:(NSString *)key {
    NSString *hex = [self currentPaletteColors][key];
    return hex ? GLColorFromHexString(hex) : nil;
}

+ (UIColor *)backgroundColor {
    return [self paletteColorForKey:@"bg"] ?: [UIColor colorNamed:kGLBackgroundColorName];
}

+ (UIColor *)surfaceColor {
    return [self paletteColorForKey:@"surface"] ?: [UIColor colorNamed:kGLSurfaceColorName];
}

+ (UIColor *)accentColor {
    return [self paletteColorForKey:@"accent"] ?: [UIColor colorNamed:kGLAccentColorName];
}

+ (UIColor *)destructiveColor {
    return [self paletteColorForKey:@"danger"] ?: [UIColor colorNamed:kGLDestructiveColorName];
}

+ (UIColor *)textPrimaryColor {
    return [self paletteColorForKey:@"text"] ?: [UIColor colorNamed:kGLTextPrimaryColorName];
}

+ (UIColor *)textSecondaryColor {
    return [self paletteColorForKey:@"text-dim"] ?: [UIColor colorNamed:kGLTextSecondaryColorName];
}

#pragma mark - Palette fetch

+ (void)loadPalette {
    // UI-test bypass: skip the cache hydrate AND the network fetch
    // entirely. Checking here (not just relying on +currentPaletteColors'
    // own check) means CI never touches the network or NSUserDefaults at
    // all for this path, which is the whole point of "bypassing the
    // network" the brief asks for — a flaky/slow DNS failure for the
    // never-baked CI host should not be able to delay or flake a
    // screenshot that already has everything it needs synchronously.
    if (GLUITestInjectedPalette() != nil) return;

    GLHydratePaletteFromDefaultsIfNeeded();
    [self refreshPaletteFromServer];
}

// Fetches GET /api/theme (which theme id is selected; nil/absent means
// Auto) and GET /native-theme.json (every theme's resolved colours) in
// parallel, and only commits the result once BOTH have answered — half a
// pair (a fresh theme id resolved against a stale/no palette, or vice
// versa) is worse than just keeping the old cached pair a little longer.
// Public (also called directly by SettingsViewController.m right after a
// successful PUT /api/theme — see GLTheme.h's doc comment); short-circuits
// under the UITEST_NATIVE_PALETTE hook so a CI run's Settings-tab flow
// can't clobber the injected fixture with a real (always-failing, since
// GL_BAKED_HOST is never baked in CI) network round-trip's null result.
+ (void)refreshPaletteFromServer {
    if (GLUITestInjectedPalette() != nil) return;

    dispatch_group_t group = dispatch_group_create();

    __block BOOL themeIdFetchSucceeded = NO;
    __block NSString *fetchedThemeId = nil;
    __block NSDictionary *fetchedPalette = nil;

    NSURL *themeURL = GLThemeServerURLWithPath(@"/api/theme");
    if (themeURL) {
        dispatch_group_enter(group);
        NSURLSessionDataTask *task = [[NSURLSession sharedSession]
            dataTaskWithURL:themeURL
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSDictionary *parsed = GLThemeJSONFromResponse(response, data, error, [NSDictionary class]);
            if (parsed) {
                id themeValue = parsed[@"theme"];
                // A null/absent "theme" is a VALID, successful answer (Auto)
                // -- only a network/parse failure (parsed == nil) should
                // leave themeIdFetchSucceeded NO.
                fetchedThemeId = [themeValue isKindOfClass:[NSString class]] ? themeValue : nil;
                themeIdFetchSucceeded = YES;
            }
            dispatch_group_leave(group);
        }];
        [task resume];
    }

    NSURL *paletteURL = GLThemeServerURLWithPath(@"/native-theme.json");
    if (paletteURL) {
        dispatch_group_enter(group);
        NSURLSessionDataTask *task = [[NSURLSession sharedSession]
            dataTaskWithURL:paletteURL
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            fetchedPalette = GLThemeJSONFromResponse(response, data, error, [NSDictionary class]);
            dispatch_group_leave(group);
        }];
        [task resume];
    }

    // No __weak-self dance needed here the way an instance method would
    // need one: `self` in a class method is the Class object itself, which
    // the Objective-C runtime never deallocates, so capturing it directly
    // in this block cannot create a retain cycle.
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        if (!themeIdFetchSucceeded || !fetchedPalette) {
            GLLog(@"GLTheme: palette fetch incomplete (themeId ok=%d, palette ok=%d) -- keeping cached/asset colours",
                  (int)themeIdFetchSucceeded, (int)(fetchedPalette != nil));
            return;
        }
        [self applyFetchedPalette:fetchedPalette themeId:fetchedThemeId];
    });
}

// Commits a freshly-fetched palette: updates the in-memory statics (so
// +currentPaletteColors reflects it immediately), persists both to
// NSUserDefaults (so next launch's synchronous hydrate sees it too, per
// +loadPalette's doc comment), then re-applies chrome now that the colours
// actually changed -- this is the "palette arrives" half of the
// re-apply requirement (GLTheme.h's +applyChromeAppearance CORRECTNESS
// NOTE); the "mode changes" half is +handleThemeDidChangeNotification:
// above.
+ (void)applyFetchedPalette:(NSDictionary *)palette themeId:(nullable NSString *)themeId {
    NSError *jsonError = nil;
    NSData *paletteData = [NSJSONSerialization dataWithJSONObject:palette options:0 error:&jsonError];
    if (jsonError) {
        GLLog(@"GLTheme: fetched palette failed to re-serialize for caching: %@", jsonError.localizedDescription);
        return;
    }

    GLCurrentPalette = palette;
    GLCurrentSelectedThemeId = themeId;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:paletteData forKey:GLThemePaletteDefaultsName];
    if (themeId) {
        [defaults setObject:themeId forKey:GLThemeSelectedIdDefaultsName];
    } else {
        [defaults removeObjectForKey:GLThemeSelectedIdDefaultsName];
    }

    [self applyChromeAppearance];
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
