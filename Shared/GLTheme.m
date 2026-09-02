#import "GLTheme.h"
#import "BakedConfig.h"
#import "GLLog.h"
#import "GLAppStateReporter.h"
#import <math.h> // sin/cos/fabs/M_PI for the pure-C gradient-angle maths below

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

// Tracks WHERE GLCurrentPalette came from, for +paletteSource
// (GLAppStateReporter). "Server" always wins once it happens: a fetch that
// succeeds this launch supersedes whatever was cached, and nothing ever
// downgrades this back to Cache — the only way GLCurrentPalette itself goes
// stale again is a fresh process (a new launch re-starts at None and
// re-hydrates from Cache before any fetch can land).
typedef NS_ENUM(NSInteger, GLPaletteSourceState) {
    GLPaletteSourceStateNone = 0,
    GLPaletteSourceStateCache,
    GLPaletteSourceStateServer,
};
static GLPaletteSourceState GLCurrentPaletteSourceState = GLPaletteSourceStateNone;

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
            GLCurrentPaletteSourceState = GLPaletteSourceStateCache;
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

// Forward declarations for two GLTheme class methods implemented down in
// @implementation GLTheme (colour-tokens section) but called from code
// ABOVE that @implementation block in this file (GLGradientBackgroundView,
// just below) — a plain class extension, so the compiler knows the
// selectors and their argument types at every call site regardless of
// textual order.
@interface GLTheme ()
+ (nullable NSDictionary *)currentGradientDescriptor;
+ (void)configureGradientLayer:(CAGradientLayer *)layer
                 withDescriptor:(NSDictionary *)descriptor
                           size:(CGSize)size;
@end

#pragma mark - Background gradient maths (pure C, no UIKit/Foundation)

// This whole block is plain C on plain doubles specifically so it can be
// checked by hand / against a worked-values table without a compiler (see
// the PR description for that table) — none of it touches UIColor, CGRect,
// or any Foundation type, and none of it needs one to be correct.
//
// CSS angle -> direction unit vector, in a coordinate system with +x right
// and +y DOWN (screen/view coordinates — NOT the maths convention where +y
// is up). CSS defines 0deg as "to the top" and increasing CLOCKWISE, so the
// direction vector is (sin A, -cos A). Worked sanity checks: 0deg ->
// (0,-1) i.e. straight up; 90deg -> (1,0) straight right; 180deg -> (0,1)
// straight down; 165deg -> (sin165, -cos165) = (~0.259, ~0.966), i.e. mostly
// down and slightly right, matching "165deg is a hair off straight-down,
// tilted clockwise (toward the right)".
static void GLGradientDirection(double angleDegrees, double *dx, double *dy) {
    double radians = angleDegrees * M_PI / 180.0;
    *dx = sin(radians);
    *dy = -cos(radians);
}

// The CSS "magic corners" gradient line for a box of the given size
// (https://www.w3.org/TR/css-images-3/#linear-gradients): the line passes
// through the box's centre, and its length is `|W·sinA| + |H·cosA|` — NOT
// simply W or H — specifically so that the first and last colour stops land
// exactly on the two corners perpendicular to the gradient line, rather than
// merely touching the box's edges (which is what a naive "line spans the
// box" construction would give you, and would visibly crop the gradient's
// authored extremes on any angle that isn't an exact multiple of 90°).
// Returns the line's two endpoints in the box's own point space (origin
// top-left, +x right, +y down).
static void GLGradientLine(double angleDegrees, double width, double height,
                            double *startX, double *startY, double *endX, double *endY) {
    double dx, dy;
    GLGradientDirection(angleDegrees, &dx, &dy);
    double length = fabs(width * dx) + fabs(height * dy);
    double half = length / 2.0;
    double cx = width / 2.0;
    double cy = height / 2.0;
    *startX = cx - dx * half;
    *startY = cy - dy * half;
    *endX = cx + dx * half;
    *endY = cy + dy * half;
}

// Projects point (px,py) onto the gradient line from (startX,startY) to
// (endX,endY) and returns how far along it the point falls, clamped to
// [0,1] — 0 at the line's start (where stop position 0 sits), 1 at its end
// (where stop position 1 sits). A zero-length line (a zero-size box) can't
// happen for any real screen/view, but degrades to 0 rather than dividing by
// zero.
static double GLGradientProjectFraction(double px, double py,
                                         double startX, double startY,
                                         double endX, double endY) {
    double dx = endX - startX;
    double dy = endY - startY;
    double lengthSquared = dx * dx + dy * dy;
    if (lengthSquared <= 0) return 0;
    double t = ((px - startX) * dx + (py - startY) * dy) / lengthSquared;
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    return t;
}

// One colour stop, in plain sRGB component space (0..1) at a given position
// (0..1) along the gradient line.
typedef struct {
    double position;
    double r, g, b;
} GLGradientStopC;

// Linear interpolation between the pair of stops bracketing fraction `t`
// (already clamped to [0,1] by the caller), in plain sRGB component space —
// CSS's own default gradient interpolation ("in srgb"), i.e. no gamma
// correction. `stops` must be sorted ascending by `position` and hold at
// least one entry; `t` before the first stop or after the last clamps to
// that stop's own colour.
static void GLGradientColorAt(const GLGradientStopC *stops, size_t count, double t,
                               double *outR, double *outG, double *outB) {
    if (t <= stops[0].position) {
        *outR = stops[0].r;
        *outG = stops[0].g;
        *outB = stops[0].b;
        return;
    }
    for (size_t i = 1; i < count; i++) {
        if (t <= stops[i].position) {
            double span = stops[i].position - stops[i - 1].position;
            double localT = span > 0 ? (t - stops[i - 1].position) / span : 0;
            *outR = stops[i - 1].r + (stops[i].r - stops[i - 1].r) * localT;
            *outG = stops[i - 1].g + (stops[i].g - stops[i - 1].g) * localT;
            *outB = stops[i - 1].b + (stops[i].b - stops[i - 1].b) * localT;
            return;
        }
    }
    const GLGradientStopC *last = &stops[count - 1];
    *outR = last->r;
    *outG = last->g;
    *outB = last->b;
}

#pragma mark - Background gradient parsing (Objective-C glue)

// Parses one already-known-non-nil "bg-gradient" object into GLGradientStopC
// entries (heap-allocated, `count` of them, sorted ascending by `position`
// — the caller must free(*outStops)) plus its angle in degrees. Raises on
// anything malformed: a "bg-gradient" key existing at all is our own
// design-tokens build's claim that a real gradient is here, so a broken one
// (missing stops, unparseable colour, non-numeric angle/position) is an
// invariant violation in OUR OWN build to surface loudly, not something to
// silently degrade to the flat background over — see this file's "no
// defensive fallback" convention.
static void GLParseGradientDescriptor(NSDictionary *raw, double *outAngleDegrees,
                                       GLGradientStopC **outStops, size_t *outCount) {
    id angleValue = raw[@"angle"];
    if (![angleValue isKindOfClass:[NSNumber class]]) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"GLTheme: bg-gradient.angle missing/non-numeric: %@", raw];
    }
    id stopsValue = raw[@"stops"];
    if (![stopsValue isKindOfClass:[NSArray class]] || [(NSArray *)stopsValue count] < 2) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"GLTheme: bg-gradient.stops missing/too short (need >= 2): %@", raw];
    }
    NSArray *stopsArray = stopsValue;
    size_t count = stopsArray.count;
    GLGradientStopC *stops = (GLGradientStopC *)malloc(sizeof(GLGradientStopC) * count);
    for (size_t i = 0; i < count; i++) {
        id stopObj = stopsArray[i];
        if (![stopObj isKindOfClass:[NSDictionary class]]) {
            free(stops);
            [NSException raise:NSInternalInconsistencyException
                        format:@"GLTheme: bg-gradient stop %zu is not an object: %@", i, stopObj];
        }
        NSDictionary *stopDict = stopObj;
        id colorValue = stopDict[@"color"];
        id positionValue = stopDict[@"position"];
        UIColor *color = [colorValue isKindOfClass:[NSString class]] ? GLColorFromHexString(colorValue) : nil;
        if (!color || ![positionValue isKindOfClass:[NSNumber class]]) {
            free(stops);
            [NSException raise:NSInternalInconsistencyException
                        format:@"GLTheme: bg-gradient stop %zu malformed: %@", i, stopObj];
        }
        CGFloat r, g, b, a;
        [color getRed:&r green:&g blue:&b alpha:&a];
        stops[i] = (GLGradientStopC){ .position = [(NSNumber *)positionValue doubleValue], .r = r, .g = g, .b = b };
    }
    // Insertion sort ascending by position — native-theme.json's gradients
    // run 2-4 stops, so an O(n^2) sort costs nothing and needs no
    // block-based qsort_b dependency for what is already sorted input in
    // every real case (design-tokens' build.mjs emits stops in order); this
    // exists only to not silently mis-render if that ever stopped being
    // true.
    for (size_t i = 1; i < count; i++) {
        GLGradientStopC key = stops[i];
        size_t j = i;
        while (j > 0 && stops[j - 1].position > key.position) {
            stops[j] = stops[j - 1];
            j--;
        }
        stops[j] = key;
    }
    *outAngleDegrees = [(NSNumber *)angleValue doubleValue];
    *outStops = stops;
    *outCount = count;
}

// Thin gradient-layer-backed view used by +applyBackgroundToView: to keep a
// screen's background gradient in sync with the screen's OWN size (which
// changes on rotation / multitasking resize / any Auto Layout-driven
// resize) without polling or KVO-observing `bounds` — a previous attempt in
// this codebase KVO'd a UIScrollView's `bounds` and caused a scroll feedback
// loop, because a scroll view's `bounds.origin` literally IS its
// `contentOffset`; this view never scrolls, but the general lesson (don't
// reactively watch `bounds` when a layout hook already fires for exactly
// this) still applies, so this uses the layout hook instead.
//
// +layerClass makes this view's own backing CALayer the CAGradientLayer
// (rather than adding a separate gradient sublayer this view would then
// have to keep positioned) — resizing the view via Auto Layout IS resizing
// the gradient layer for free; only the unit-space start/end points still
// need recomputing per size (they depend on the box's aspect ratio, not
// just its frame), which -layoutSubviews below does.
@interface GLGradientBackgroundView : UIView
@property(nonatomic, copy, nullable) NSDictionary *gradientDescriptor;
@end

@implementation GLGradientBackgroundView

+ (Class)layerClass {
    return [CAGradientLayer class];
}

- (void)setGradientDescriptor:(nullable NSDictionary *)gradientDescriptor {
    _gradientDescriptor = [gradientDescriptor copy];
    [self reconfigureGradient];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self reconfigureGradient];
}

- (void)reconfigureGradient {
    if (!self.gradientDescriptor) return;
    CGSize size = self.bounds.size;
    // Bounds are still zero the instant this view is inserted (Auto Layout
    // hasn't resolved its constraints yet) — -setGradientDescriptor: calling
    // this immediately would just no-op here, harmlessly, and the real
    // configure happens once -layoutSubviews fires with a real size.
    if (size.width <= 0 || size.height <= 0) return;
    [GLTheme configureGradientLayer:(CAGradientLayer *)self.layer
                      withDescriptor:self.gradientDescriptor
                                size:size];
}

@end

#pragma mark - Chrome background fractions (pure geometry, no palette lookup)

// Both bars in +applyChromeAppearance below sample
// +backgroundColorAtVerticalFraction: at their OWN vertical centre,
// expressed as a fraction of the FULL SCREEN height (not the bar's own
// height) -- that accessor measures against UIScreen.mainScreen.bounds, see
// its doc comment. 44pt/49pt are UIKit's own long-documented standard
// (non-large-title, non-accessibility-size) heights for UINavigationBar and
// UITabBar respectively -- not values made up for this file -- so these
// fractions track the real bar, not a guess at one; a large-title/
// accessibility-size bar is somewhat taller than this in practice, meaning
// the actual sampled point can drift a few points from the bar's true
// centre in those configurations, but the resulting colour error is a
// fraction of the gradient's own smooth motion across a couple of points
// and not visible in practice.
static CGFloat const kGLNavigationBarStandardHeight = 44.0;
static CGFloat const kGLTabBarStandardHeight = 49.0;

static CGFloat GLNavigationBarBackgroundFraction(void) {
    CGFloat screenHeight = [UIScreen mainScreen].bounds.size.height;
    if (screenHeight <= 0) return 0.0;
    return (kGLNavigationBarStandardHeight / 2.0) / screenHeight;
}

static CGFloat GLTabBarBackgroundFraction(void) {
    CGFloat screenHeight = [UIScreen mainScreen].bounds.size.height;
    if (screenHeight <= 0) return 1.0;
    return 1.0 - (kGLTabBarStandardHeight / 2.0) / screenHeight;
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

+ (NSString *)currentModeName {
    switch ([self currentMode]) {
        case GLThemeModeLight: return @"light";
        case GLThemeModeDark: return @"dark";
        case GLThemeModeSystem: return @"system";
    }
    [NSException raise:NSInternalInconsistencyException format:@"unhandled GLThemeMode %ld", (long)[self currentMode]];
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

    // A window's own trait collection is the most accurate answer, because it
    // carries any +applyCurrentMode override this class set on it. Before a
    // window exists there is still a real answer to give -- the process-wide
    // current trait collection, which reflects the device's appearance -- and
    // giving it matters: this method runs from +applyChromeAppearance at
    // AppDelegate time, BEFORE any scene has connected, and a hardcoded
    // "light" there baked the wrong palette variant into the tab/nav bar
    // appearance objects for the whole launch (visible as a light-mode
    // chrome flash under a dark-mode app until the next mode change or
    // palette fetch re-applied them).
    UIUserInterfaceStyle resolved = UITraitCollection.currentTraitCollection.userInterfaceStyle;
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

// Resolves the currently-loaded palette's leaf dictionary, or nil if none is
// available yet (never fetched, fetch failed, and nothing cached from a
// previous launch). A UITEST injection always wins outright, ignoring the
// selected theme id / effective mode entirely — see GLUITestInjectedPalette's
// header comment.
//
// Declared `id` values, not `NSString *`: this leaf holds the six flat
// "#rrggbb" colour strings PLUS an optional "bg-gradient" key whose value is
// itself an object (see +currentGradientDescriptor below), so a single
// NSString-valued generic would be a lie about half this dictionary's
// entries. Generics are a compile-time hint only, never enforced at
// runtime, so this changes no actual behaviour — every existing
// +paletteColorForKey: call site still gets the NSString it expects for
// every key it actually asks for.
//
// Auto (GLCurrentSelectedThemeId == nil) resolves `themeKey` to the
// effective MODE NAME itself ("light"/"dark") rather than looking anything
// up first: native-theme.json's own "light"/"dark" entries are exactly
// tokens.json's un-family'd base themes (the same ones the web's bare
// `:root`/`@media(prefers-color-scheme)` fallback paints when no
// `data-theme` is set), so `palette["light"]["light"]` /
// `palette["dark"]["dark"]` IS the correct Auto resolution for each mode —
// no separate "auto" case to special-render.
+ (nullable NSDictionary<NSString *, id> *)currentPaletteColors {
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

#pragma mark - Background gradient

// The raw "bg-gradient" object for the current theme/variant (native-
// theme.json's own shape — {angle, stops:[{color,position}]}), or nil when
// the current variant authors no gradient at all. Absent is the normal,
// common no-gradient path (most themes are flat) and is NOT malformed —
// every caller here treats nil as "fall through to the flat colour", not as
// an error. Reuses +currentPaletteColors' own resolution (UITEST injection,
// Auto vs. named theme, mode) so the gradient always tracks exactly the
// same theme/variant every other colour accessor in this file resolves to.
+ (nullable NSDictionary *)currentGradientDescriptor {
    NSDictionary *colors = [self currentPaletteColors];
    id raw = colors[@"bg-gradient"];
    if (raw == nil) return nil;
    if (![raw isKindOfClass:[NSDictionary class]]) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"GLTheme: bg-gradient present but not an object: %@", raw];
    }
    return raw;
}

// Configures `layer`'s colours/locations/start&endPoint from `descriptor`
// (a raw bg-gradient object, already known non-nil) for a box of the given
// `size`. Shared by +backgroundGradientLayer (screen-sized) and
// GLGradientBackgroundView (host-view-sized, recomputed on every layout
// pass) so both draw exactly the CSS gradient line for whatever box they
// are actually filling, rather than one geometry computed for a box of a
// different aspect ratio and stretched to fit.
+ (void)configureGradientLayer:(CAGradientLayer *)layer
                 withDescriptor:(NSDictionary *)descriptor
                           size:(CGSize)size {
    double angleDegrees;
    GLGradientStopC *stops;
    size_t count;
    GLParseGradientDescriptor(descriptor, &angleDegrees, &stops, &count);

    double startX, startY, endX, endY;
    GLGradientLine(angleDegrees, size.width, size.height, &startX, &startY, &endX, &endY);

    NSMutableArray *cgColors = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray<NSNumber *> *locations = [NSMutableArray arrayWithCapacity:count];
    for (size_t i = 0; i < count; i++) {
        UIColor *color = [UIColor colorWithRed:stops[i].r green:stops[i].g blue:stops[i].b alpha:1.0];
        [cgColors addObject:(id)color.CGColor];
        [locations addObject:@(stops[i].position)];
    }
    free(stops);

    layer.colors = cgColors;
    layer.locations = locations;
    // Per-axis unit-space conversion — deliberately NOT a naive
    // angle->(cos,sin) unit vector assigned straight to startPoint/endPoint:
    // CAGradientLayer normalises startPoint/endPoint separately against the
    // layer's own width and height (its "unit space" is a unit SQUARE
    // mapped onto a box that usually isn't square), so the only way to get
    // the actual CSS angle out the other end is to compute the real
    // point-space line for THIS size first (above) and only then divide by
    // (width, height) — which is exactly what the CSS spec's own
    // to-canvas-space conversion does, and what a direct angle->unit-vector
    // shortcut would skip, skewing the rendered angle on any non-square
    // layer.
    layer.startPoint = CGPointMake(size.width > 0 ? startX / size.width : 0.5,
                                   size.height > 0 ? startY / size.height : 0.0);
    layer.endPoint = CGPointMake(size.width > 0 ? endX / size.width : 0.5,
                                 size.height > 0 ? endY / size.height : 1.0);
}

// See GLTheme.h's doc comment. Screen-sized (UIScreen.mainScreen.bounds) --
// the box the CSS gradient this mirrors is itself drawn across.
+ (nullable CAGradientLayer *)backgroundGradientLayer {
    NSDictionary *descriptor = [self currentGradientDescriptor];
    if (!descriptor) return nil;

    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    CAGradientLayer *layer = [CAGradientLayer layer];
    layer.frame = CGRectMake(0, 0, screenSize.width, screenSize.height);
    [self configureGradientLayer:layer withDescriptor:descriptor size:screenSize];
    return layer;
}

// See GLTheme.h's doc comment.
+ (UIColor *)backgroundColorAtVerticalFraction:(CGFloat)fraction {
    NSDictionary *descriptor = [self currentGradientDescriptor];
    if (!descriptor) return [self backgroundColor];

    double angleDegrees;
    GLGradientStopC *stops;
    size_t count;
    GLParseGradientDescriptor(descriptor, &angleDegrees, &stops, &count);

    // Measured against the FULL SCREEN, not whatever small frame the caller
    // (a tab bar, a nav bar) actually has -- this is sampling one point out
    // of the same conceptual gradient the web content paints across the
    // whole viewport, which is the entire point: the chrome's colour at its
    // own y-position has to match the web content immediately next to it at
    // that SAME y-position on the SAME screen, not some other box's notion
    // of that fraction.
    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    double startX, startY, endX, endY;
    GLGradientLine(angleDegrees, screenSize.width, screenSize.height, &startX, &startY, &endX, &endY);
    double t = GLGradientProjectFraction(0.5 * screenSize.width, fraction * screenSize.height,
                                        startX, startY, endX, endY);
    double r, g, b;
    GLGradientColorAt(stops, count, t, &r, &g, &b);
    free(stops);
    return [UIColor colorWithRed:r green:g blue:b alpha:1.0];
}

// See GLTheme.h's doc comment.
+ (void)applyBackgroundToView:(UIView *)view {
    NSDictionary *descriptor = [self currentGradientDescriptor];

    // Tear down any gradient background this method previously installed on
    // `view` before deciding what to do next -- a theme switch from a
    // gradient variant to a flat one (or vice versa) must never leave a
    // stale layer from the LAST call showing through/behind whatever this
    // call is about to set.
    for (UIView *subview in [view.subviews copy]) {
        if ([subview isKindOfClass:[GLGradientBackgroundView class]]) {
            [subview removeFromSuperview];
        }
    }

    if (!descriptor) {
        view.backgroundColor = [self backgroundColor];
        return;
    }

    GLGradientBackgroundView *background = [[GLGradientBackgroundView alloc] init];
    background.translatesAutoresizingMaskIntoConstraints = NO;
    [view insertSubview:background atIndex:0];
    [NSLayoutConstraint activateConstraints:@[
        [background.topAnchor constraintEqualToAnchor:view.topAnchor],
        [background.bottomAnchor constraintEqualToAnchor:view.bottomAnchor],
        [background.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [background.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
    ]];
    // Bounds are zero right now (Auto Layout hasn't run yet) -- this no-ops
    // harmlessly and GLGradientBackgroundView's own -layoutSubviews performs
    // the real configure once a real size exists, and again on every future
    // resize.
    background.gradientDescriptor = descriptor;
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
    GLCurrentPaletteSourceState = GLPaletteSourceStateServer;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:paletteData forKey:GLThemePaletteDefaultsName];
    if (themeId) {
        [defaults setObject:themeId forKey:GLThemeSelectedIdDefaultsName];
    } else {
        [defaults removeObjectForKey:GLThemeSelectedIdDefaultsName];
    }

    [self applyChromeAppearance];

    // GLWebModuleViewController's own re-theme, distinct from and IN
    // ADDITION TO GLThemeDidChangeNotification below: a palette can change
    // (new theme id, or the same id resolving differently) without the
    // light/dark/system MODE changing at all, and a mode flip with no new
    // palette shouldn't wait on a network round trip either -- two
    // different triggers, two different notifications, one observer for
    // each.
    [[NSNotificationCenter defaultCenter] postNotificationName:GLPaletteDidChangeNotification
                                                          object:nil];

    // A palette refresh can change +effectiveModeName's resolved colours (a
    // new theme id, or the same id resolving differently) without posting
    // GLThemeDidChangeNotification — that notification is reserved for mode
    // (light/dark/system) flips, see +setCurrentMode above. Reporting here
    // directly is what lets an app-state report reflect a variant change
    // picked in Settings without waiting for the next relaunch.
    [GLAppStateReporter report];
}

+ (nullable NSString *)selectedThemeId {
    GLHydratePaletteFromDefaultsIfNeeded();
    return GLCurrentSelectedThemeId;
}

+ (NSString *)paletteSource {
    GLHydratePaletteFromDefaultsIfNeeded();
    switch (GLCurrentPaletteSourceState) {
        case GLPaletteSourceStateServer: return @"server";
        case GLPaletteSourceStateCache: return @"cache";
        case GLPaletteSourceStateNone: return @"asset-fallback";
    }
    [NSException raise:NSInternalInconsistencyException format:@"unhandled GLPaletteSourceState %ld", (long)GLCurrentPaletteSourceState];
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
    // NOT surfaceColor: see GLTheme.h's +applyChromeAppearance doc comment
    // for why the tab bar's background has to track the gradient/flat
    // colour the web content paints at the SAME screen position, not a
    // separate flat token.
    appearance.backgroundColor = [self backgroundColorAtVerticalFraction:GLTabBarBackgroundFraction()];

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
    // NOT surfaceColor: see GLTheme.h's +applyChromeAppearance doc comment.
    appearance.backgroundColor = [self backgroundColorAtVerticalFraction:GLNavigationBarBackgroundFraction()];
    appearance.titleTextAttributes = @{ NSForegroundColorAttributeName: [self textPrimaryColor] };
    appearance.largeTitleTextAttributes = @{ NSForegroundColorAttributeName: [self textPrimaryColor] };
    return appearance;
}

+ (void)applyChromeAppearance {
    // Observable signal for sim-test.yml's System-mode appearance pass: a
    // pixel check can't stand in for this (CI runs iOS 26, where the tab bar
    // ignores UITabBarAppearance.backgroundColor entirely -- measured), and
    // no explicit-mode pass can reach the System-resolution branch of
    // +effectiveModeName at all, since that method short-circuits on an
    // explicit mode before ever touching it. This line is the only place
    // that branch's real answer becomes visible from outside the process.
    GLLog(@"GLTheme: applyChromeAppearance resolved %@ (mode pref %@)", [self effectiveModeName], [self currentModeName]);
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
