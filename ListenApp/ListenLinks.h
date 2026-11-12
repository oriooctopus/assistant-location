// ListenLinks: pure routing decision for taps inside the Listen web view, kept free of UIKit/WebKit so the
// host-less SharedTests bundle can compile it. Mirrors GLWebModuleViewController's link handling.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ListenLinks : NSObject

/// YES when `url` should be handed to the system (Safari, mail, ...) instead of loading in the web view.
/// `isNewWindow`: a target=_blank / window.open request (always external; there is no second web view).
/// `isLinkActivation`: a tapped link in the page. file:// and same-host http(s) stay in-app; anything else is external.
/// Any other navigation (script, reload, subresource) is never external.
+ (BOOL)shouldOpenExternally:(nullable NSURL *)url
                     pageURL:(nullable NSURL *)pageURL
                 isNewWindow:(BOOL)isNewWindow
            isLinkActivation:(BOOL)isLinkActivation;

/// The page's `appInfo` reply: {native: ListenNativeVersion from Info.plist, or 0 for an unstamped (local dev) build, so the
/// page never shows the update bar for it}. `info` is the bundle's infoDictionary.
+ (NSDictionary *)appInfoFromBundleInfo:(nullable NSDictionary *)info;

/// The page's `openURL` argument: the URL when `raw` is an https URL with a host, else nil. Nothing else may be opened from the page.
+ (nullable NSURL *)installURLFromString:(nullable id)raw;

@end

NS_ASSUME_NONNULL_END
