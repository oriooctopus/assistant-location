// Thin GLWebModuleViewController subclass whose only job is listening for
// the two "start in this mode" notifications SessionsModule posts from
// +moduleHandleURL: (overland://session/voice, overland://session/text) and
// forwarding them into session.html once it's loaded. GLWebModuleViewController
// itself has no notion of a "mode" -- every other MANAGED page (settings.html,
// more.html) always opens the same way every time, so there was nowhere to
// hang this before Sessions needed it.

#import "GLWebModuleViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface SessionsViewController : GLWebModuleViewController
@end

NS_ASSUME_NONNULL_END
