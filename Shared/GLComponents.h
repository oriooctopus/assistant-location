// Small factory methods for the UI pieces every module currently rebuilds
// independently and differently: the primary button (blue/rounded in
// Events/Todos/Upload, no background or radius at all in AutoJournal), the
// secondary status label, a failure presentation (today: full-screen error
// view, red status text, colour-only state, and UIAlertController — four
// different ways to tell the user something failed), an empty state, and a
// toast (today: confirmations are label mutations that never clear).
//
// All of these read GLTheme tokens; none hardcode a colour, font or metric.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface GLComponents : NSObject

/// Blue-filled, white text, GLTheme.cornerRadius corners, GLTheme.controlHeight
/// tall. Caller is responsible for adding the height constraint if the
/// button isn't placed in a stack view that would otherwise stretch it.
+ (UIButton *)primaryButtonWithTitle:(NSString *)title;

/// Multi-line, centred, secondary-coloured caption label — the "status under
/// the main control" pattern Events/Todos/Upload/AutoJournal each rebuild.
+ (UILabel *)statusLabel;

/// A centred message with no action, for a tab that has nothing to show yet.
+ (UIView *)emptyStateViewWithMessage:(NSString *)message;

/// A centred message plus a "Retry" button wired to `retryHandler`, for a
/// full-screen failure. Mirrors GLWebModuleViewController's error view so
/// the two failure presentations converge over time as modules adopt this.
+ (UIView *)failureViewWithMessage:(NSString *)message
                       retryHandler:(void (^)(void))retryHandler;

/// Transient confirmation banner, auto-dismissing after ~2s, added to
/// `view` and animated in/out. Replaces the "mutate a label and never clear
/// it" pattern used today.
+ (void)showToastInView:(UIView *)view message:(NSString *)message;

@end

NS_ASSUME_NONNULL_END
