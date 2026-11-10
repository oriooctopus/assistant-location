// GLVoiceRecordings -- the file side of the Sessions voice capture (GLWebBridge voiceStart/voiceStop): where a recording
// lives while it is made, how it enters the durable outbox, and the launch sweep that hands recordings a dead process
// left behind to the outbox so voicePending surfaces them. Foundation-only so SharedTests can compile it.

#import <Foundation/Foundation.h>

#import "GLDurableOutbox.h"

NS_ASSUME_NONNULL_BEGIN

@interface GLVoiceRecordings : NSObject

/// Application Support/VoiceRecordings. Not tmp: iOS may purge tmp, and a recording must outlive a kill.
+ (NSURL *)defaultDirectory;

/// A fresh session-voice-<uuid>.m4a url inside `directory`, creating the directory first. nil with `error` when it
/// could not be created.
+ (nullable NSURL *)newRecordingURLInDirectory:(NSURL *)directory error:(NSError **)error;

/// Queues the m4a at `url` as a `session-voice` outbox item (POST /sessions/transcribe, `lang` "multi" selects the
/// code-switching transcriber, 422 accepted, transient 5xx retried) and deletes the file once the outbox holds it on
/// disk. meta carries launchId (the page's id for its Recent row, "" when unknown) and recovered (YES for a clip nobody
/// was waiting on: found by the sweep, or displaced by a second voiceStart). Returns the item id; nil with `error` when
/// the file is empty or unreadable or the outbox write failed, and then the file is left as it is.
+ (nullable NSString *)enqueueRecordingAtURL:(NSURL *)url
                                      outbox:(GLDurableOutbox *)outbox
                                        lang:(nullable NSString *)lang
                                    launchId:(nullable NSString *)launchId
                                   recovered:(BOOL)recovered
                                       error:(NSError **)error;

/// Enqueues every session-voice-*.m4a in `directory` (recovered:YES) and returns how many it queued. Empty files are
/// deleted; a file the outbox could not take is left for the next launch. Call only when no recording is in progress
/// (launch). The caller flushes the outbox afterwards.
+ (NSUInteger)recoverRecordingsInDirectory:(NSURL *)directory outbox:(GLDurableOutbox *)outbox;

@end

NS_ASSUME_NONNULL_END
