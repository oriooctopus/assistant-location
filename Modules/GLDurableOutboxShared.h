// The app-wide outbox (Application Support/DurableOutbox, real box URL and
// token). Separate from GLDurableOutbox.h because it needs BakedConfig, which
// SharedTests cannot compile.

#import "GLDurableOutbox.h"

NS_ASSUME_NONNULL_BEGIN

@interface GLDurableOutbox (Shared)
/// First call creates the outbox, drains it, and subscribes to app-active so
/// every foreground drains it again.
+ (GLDurableOutbox *)shared;
@end

NS_ASSUME_NONNULL_END
