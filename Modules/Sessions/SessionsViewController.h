// Thin GLWebModuleViewController subclass whose only job is listening for
// the "start in this mode" notifications and the attachment-ids notification
// SessionsModule posts from +moduleHandleURL:
// (overland://session/voice, overland://session/text,
// ?attach=<id>,<id>,...) and forwarding them into session.html once it's
// loaded. GLWebModuleViewController itself has no notion of a "mode" or of
// attachments -- every other MANAGED page (settings.html, more.html) always
// opens the same way every time, so there was nowhere to hang this before
// Sessions needed it.

#import "GLWebModuleViewController.h"

NS_ASSUME_NONNULL_BEGIN

/// Posted by SessionsModule.m's +moduleHandleURL: when the deep link carries
/// a non-empty, already-validated `attach=` id list. userInfo carries the
/// list under kSessionsAttachIDsKey.
extern NSString *const kSessionsAttachNotification;
extern NSString *const kSessionsAttachIDsKey;

@interface SessionsViewController : GLWebModuleViewController
@end

NS_ASSUME_NONNULL_END
