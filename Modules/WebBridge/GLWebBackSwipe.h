#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Decides who owns the back-swipe on a screen hosting a web module.
 *
 * A web module pushed onto the More navigation controller has two candidates
 * for the same left-edge swipe: the navigation controller's pop (back to the
 * More page) and the WKWebView's own back-forward gesture (back one step in the
 * page's history, e.g. Outfits' piece view -> its list). Left alone, the pop
 * wins and every swipe leaves the app (Oliver, 2026-10-03: "if i swipe back it
 * takes me back to the more page rather than within the outfits app").
 *
 * So the page owns the swipe while it has history to go back to, and the
 * navigation controller owns it once the page is at its first screen. The
 * owning view controller calls this whenever the page's canGoBack changes and
 * when it appears, and calls it with NO when it disappears so the next screen
 * gets the navigation gestures back.
 *
 * Lives in Modules/ (file-system-synchronized, no project.pbxproj entry) and is
 * split out of GLWebModuleViewController so it is testable without a
 * WKWebView, which cannot run web content in the host-less SharedTests bundle
 * (see GLWebKeyboardFocusTests).
 */
@interface GLWebBackSwipe : NSObject

/// Enables the navigation controller's pop gestures (the edge pop, plus the
/// iOS 26 full-width content pop where present) exactly when `pageCanGoBack`
/// is NO. A nil `navigationController` (a module hosted directly in a tab) is
/// a no-op: there is nothing to pop, and the web view's own gesture already
/// covers in-page history.
+ (void)applyPageCanGoBack:(BOOL)pageCanGoBack
    toNavigationController:(nullable UINavigationController *)navigationController;

/// The iOS 26 full-width pop gesture, or nil on an OS without it. Looked up by
/// name so this compiles against an SDK that predates it.
+ (nullable UIGestureRecognizer *)contentPopGestureRecognizerOf:(UINavigationController *)navigationController;

@end

NS_ASSUME_NONNULL_END
