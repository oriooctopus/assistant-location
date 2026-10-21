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

@end

NS_ASSUME_NONNULL_END
