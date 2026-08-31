#import "GLAppStateReporter.h"

#import <UIKit/UIKit.h>
#import <sys/utsname.h>

#import "BakedConfig.h"
#import "BuildStamp.generated.h"
#import "GLTheme.h"

// Same host + port as GLTheme.m's palette fetch (:8304) — this piggybacks on
// the existing theme server rather than standing up a separate one. Built
// the same way GLTheme.m's own GLThemeServerURLWithPath() is, NOT via
// GLEndpoints.h's GLEndpointURL(): that helper *raises* when GL_BAKED_HOST
// is unbaked (every simulator/CI build), and +report runs on literally every
// launch and every theme change, which is exactly the "crash before the
// first frame renders" bug SceneDelegate.m's GLSceneDebugLog guard already
// exists to avoid. The port is duplicated rather than shared via a header,
// same call GLTheme.m itself made about not sharing its copy with
// SettingsViewController.m — three one-line static constants, not worth it.
static NSInteger const kGLAppStateServerPort = 8304;

@implementation GLAppStateReporter

// Registers the theme-change half of the reporting contract (GLTheme.h's
// doc comment on +report): the "palette refresh commits" half is a direct
// call from GLTheme.m's own +applyFetchedPalette:themeId:, because that
// path does NOT post GLThemeDidChangeNotification (that notification is
// reserved for light/dark/system mode flips). `self` here is the Class
// object, which the runtime never deallocates, so no weak-self dance is
// needed — same reasoning GLTheme.m's own +load gives for the same pattern.
+ (void)load {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(report)
                                                  name:GLThemeDidChangeNotification
                                                object:nil];
}

// Factored out of +report (see GLAppStateReporter.h's doc comment on this
// method) so GLCrashReporter.m can stamp a crash report with the exact same
// build/theme identity fields without a second, driftable copy of this list.
+ (NSDictionary<NSString *, NSString *> *)currentIdentifyingFields {
    // hw.machine (e.g. "iPhone16,2") is the same identifier Apple's own
    // device-support tooling keys off; UIDevice's own `.model`/`.name` give
    // only the generic "iPhone" or the user's own device name, neither of
    // which distinguishes hardware generations.
    struct utsname systemInfo;
    uname(&systemInfo);
    NSString *device = [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding] ?: @"unknown";

    return @{
        @"buildStamp": GL_BUILD_STAMP,
        @"bundleVersion": [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"",
        @"commit": GL_BAKED_COMMIT,
        @"themeId": [GLTheme selectedThemeId] ?: @"auto",
        @"mode": [GLTheme currentModeName],
        @"resolvedVariant": [GLTheme effectiveModeName],
        @"paletteSource": [GLTheme paletteSource],
        @"device": device,
        @"systemVersion": [UIDevice currentDevice].systemVersion,
    };
}

+ (void)report {
    // Mirrors SceneDelegate.m's GLSceneDebugLog guard exactly: an unbaked
    // host means this is a simulator/CI build with no server to report to,
    // and building the URL below would just be reporting garbage
    // (http://NO_HOST_BAKED_IN:8304/...). Returning here means a build with
    // a missing/broken secret produces zero network traffic for this
    // feature instead of one doomed DNS lookup per launch and per theme
    // change.
    if (GL_BAKED_HOST.length == 0 || [GL_BAKED_HOST isEqualToString:@"NO_HOST_BAKED_IN"]) {
        return;
    }

    NSString *urlString = [NSString stringWithFormat:@"http://%@:%ld/api/app-state",
                           GL_BAKED_HOST, (long)kGLAppStateServerPort];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        return;
    }

    NSDictionary *body = [self currentIdentifyingFields];

    NSError *jsonError = nil;
    NSData *payload = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError];
    if (jsonError) {
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPBody = payload;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    // Fire-and-forget: no completion handler. This is a best-effort
    // diagnostic signal, not something the app's own behaviour depends on —
    // wiring up retry/error handling here would spend effort making a
    // best-effort report look like a guarantee it isn't.
    [[[NSURLSession sharedSession] dataTaskWithRequest:request] resume];
}

@end
