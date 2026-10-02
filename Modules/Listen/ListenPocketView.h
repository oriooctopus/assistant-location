// ListenPocketView: the full-screen black "pocket mode" overlay from
// PROTOCOL.md. Proximity monitoring on, idle timer off, brightness at minimum
// (all restored on -dismiss), touches ignored except the gesture set below.
// Gestures call the same ListenPlayer methods the web bridge does.

#import <UIKit/UIKit.h>

@class ListenPlayer;

NS_ASSUME_NONNULL_BEGIN

@interface ListenPocketView : UIView

/// Three-finger tap. The page owns the data, so the owner raises `command save`.
@property (nonatomic, copy, nullable) void (^onSave)(void);
/// The exit button's 1 s long-press fired. The owner calls -dismiss.
@property (nonatomic, copy, nullable) void (^onExitRequested)(void);
/// A gesture's player call failed; the owner raises an `error` event.
@property (nonatomic, copy, nullable) void (^onError)(NSString *message);

- (instancetype)initWithPlayer:(ListenPlayer *)player NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(CGRect)frame NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/// Adds the overlay above everything in `window` and applies the device
/// settings. Returns an error string if the window has no screen.
- (nullable NSString *)presentInWindow:(UIWindow *)window;
/// Removes the overlay and restores brightness, idle timer and proximity.
- (void)dismiss;
/// One line of faint status text ("Original 3/12") for when the phone is out
/// of the pocket.
- (void)setStatusText:(NSString *)text;

@end

NS_ASSUME_NONNULL_END
