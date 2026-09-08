#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Owns a hosted view's bottom edge, moving it between the safe area and the
 * container's true bottom as the keyboard comes and goes.
 *
 * ## Why this exists
 *
 * A web module's view stops at the safe-area guide. On a tab-bar screen that
 * means it stops ABOVE the tab bar, which is deliberate: a page painting behind
 * the bar flips the bar's system material to follow the page's colour, a bug
 * already measured on device once and reverted (see GLWebModuleViewController's
 * topInsetView comment).
 *
 * With the keyboard up, none of that applies -- the keyboard covers the tab bar
 * completely. But the view's bottom stayed put, leaving a band between it and
 * the keyboard's top edge showing the flat container background under a page
 * that paints a gradient. It read as a gap under the add-todo composer (Oliver,
 * 2026-09-08). While the keyboard is up there is nothing behind that band to
 * protect, so the view extends into it and the page's own background reaches
 * the keyboard's edge.
 *
 * Split out of the view controller so this is testable without a WKWebView: it
 * depends on nothing but UIKit, and the hosted view can be any UIView. That
 * matters because a WKWebView cannot run web content at all in a host-less
 * XCTest bundle (see GLWebKeyboardFocusTests), so a test written against the
 * real controller could not observe anything.
 */
@interface GLKeyboardWebInset : NSObject

/**
 * Creates both bottom constraints, activates the safe-area one, and starts
 * listening for keyboard notifications. `hosted` must already be a subview of
 * `container` with translatesAutoresizingMaskIntoConstraints turned off; its
 * other three edges are the caller's business and are left untouched.
 */
+ (instancetype)attachTo:(UIView *)hosted inContainer:(UIView *)container;

/// YES while the hosted view's bottom is pinned to the container's true bottom
/// rather than to its safe area.
@property(nonatomic, readonly) BOOL extendsBelowSafeArea;

/**
 * Moves the bottom edge. `animationInfo` is a keyboard notification's userInfo,
 * used for the duration and curve so the edge travels with the keyboard; pass
 * nil to apply the change immediately without animating.
 */
- (void)setExtendsBelowSafeArea:(BOOL)extends animationInfo:(nullable NSDictionary *)animationInfo;

@end

NS_ASSUME_NONNULL_END
