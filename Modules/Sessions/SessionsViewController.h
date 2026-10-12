// Thin GLWebModuleViewController subclass whose only job is listening for
// the "start in this mode" notifications and the attachment-ids notification
// SessionsModule posts from +moduleHandleURL:
// (overland://session/voice, overland://session/text,
// ?attach=<id>,<id>,... for already-uploaded images, ?handoff=<uuid>,<uuid>
// for photos the share extension left in the shared keychain) and
// forwarding them into session.html once it's
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

/// Posted when the deep link carries a validated `handoff=` uuid list: keychain
/// item names (ShareToDesktop wrote the JPEGs there; no upload happened).
/// userInfo carries the list under kSessionsHandoffIDsKey.
extern NSString *const kSessionsHandoffNotification;
extern NSString *const kSessionsHandoffIDsKey;

@interface SessionsViewController : GLWebModuleViewController
@end

NS_ASSUME_NONNULL_END
