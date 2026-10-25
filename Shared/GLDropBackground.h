// Background-session half of the /drop upload, shared by the share extension
// and the containing app.
//
// Why it exists: an in-process NSURLSession dies with the process that owns
// it, and a share extension is killed the moment the sheet is dismissed (or
// jetsammed), taking a half-sent photo with it -- the server then logs
// "upload failed: aborted" and the user never learns. A background session is
// run by nsurlsessiond instead, so the transfer outlives the extension. Three
// consequences shape everything below:
//   - background upload tasks must be fromFile:, so the shared item is staged
//     into the App Group container (GLDropAppGroup) first;
//   - the session carries sharedContainerIdentifier = that group, which is what
//     lets iOS relaunch the CONTAINING APP when the extension is gone;
//   - completion is reported to a delegate, in whichever process is alive. The
//     extension if it still is, otherwise the app, via
//     -application:handleEventsForBackgroundURLSession:completionHandler: which
//     calls +reconnectSessionWithIdentifier:completionHandler:.
// Either process posts the failure notification, so a failed file is reported
// even when nothing was on screen.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Must be listed in com.apple.security.application-groups of Overland.entitlements
/// AND ShareToDesktop/ShareToDesktop.entitlements, and enabled on both bundle ids.
extern NSString *const GLDropAppGroup;

/// Every drop session identifier starts with this; the rest is a UUID so that
/// two share sheets open at once never fight over one identifier.
extern NSString *const GLDropSessionIdentifierPrefix;

/// (filename, failureReason) -- reason is nil on success. Main queue.
typedef void (^GLDropTaskCompletion)(NSString *filename, NSString *_Nullable reason);

/// (identifier, title, body, done) -- posts one local notification and calls
/// done when the system has accepted it. Replaceable so tests can observe.
typedef void (^GLDropNotifier)(NSString *identifier, NSString *title, NSString *body,
                               void (^done)(void));

@interface GLDropBackground : NSObject <NSURLSessionDataDelegate>

/// Receives one-line trace messages (process-specific prefix added by the
/// handler's owner). Set once per process at launch.
@property(class, nonatomic, copy, nullable) void (^logHandler)(NSString *line);

#pragma mark - Pure helpers (unit-tested)

+ (BOOL)ownsSessionIdentifier:(NSString *)identifier;

/// Background configuration with the group container set and launch events on.
+ (NSURLSessionConfiguration *)configurationWithIdentifier:(NSString *)identifier;

/// <group container>/GLDropStaging, or nil when the App Group is not available
/// to this process (entitlement missing).
+ (nullable NSURL *)defaultStagingRoot;

/// Moves a staged temp file into `root`/<uuid>/<filename>. Returns the new URL
/// and the taskDescription ("<uuid>/<filename>") that maps a task back to it
/// and to the filename shown in a notification.
+ (nullable NSURL *)moveFileAtURL:(NSURL *)source
                         filename:(NSString *)filename
                           toRoot:(NSURL *)root
                  taskDescription:(NSString *_Nullable *_Nullable)taskDescription
                            error:(NSString *_Nullable *_Nullable)error;

/// nil for a 2xx response with no error; otherwise a few plain words
/// ("connection lost", "server returned HTTP 413").
+ (nullable NSString *)failureReasonForResponse:(nullable NSURLResponse *)response
                                          error:(nullable NSError *)error;

+ (NSString *)notificationTitle;
+ (NSString *)notificationBodyForFilename:(NSString *)filename reason:(NSString *)reason;

#pragma mark - Session

/// A new session under a fresh identifier (share extension).
+ (instancetype)newUploadSession;

/// The app's side of -application:handleEventsForBackgroundURLSession:...:
/// recreates the session with the same identifier so its pending callbacks are
/// delivered, and calls completionHandler once they all have been.
+ (instancetype)reconnectSessionWithIdentifier:(NSString *)identifier
                             completionHandler:(void (^)(void))completionHandler;

- (instancetype)initWithIdentifier:(NSString *)identifier NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, copy, readonly) NSString *identifier;
@property(nonatomic, strong) NSURL *stagingRoot;
@property(nonatomic, copy) GLDropNotifier notifier;
/// The underlying session; created on first use.
@property(nonatomic, strong, readonly) NSURLSession *session;

/// Queues an upload of a file already staged by +moveFileAtURL:... and starts
/// it. `progress` and `completion` only fire while this process stays alive.
- (NSURLSessionUploadTask *)uploadStagedFileAtURL:(NSURL *)staged
                                  taskDescription:(NSString *)taskDescription
                                      contentType:(NSString *)contentType
                                       toEndpoint:(NSString *)endpoint
                                            token:(NSString *)token
                                         progress:(nullable void (^)(int64_t sent, int64_t total))progress
                                       completion:(nullable GLDropTaskCompletion)completion;

/// Posts one failure notification through `notifier` (identifier makes a
/// repeat replace rather than stack). Also used for a file that failed to load
/// before any task existed.
- (void)postFailureNotificationWithIdentifier:(NSString *)identifier
                                     filename:(NSString *)filename
                                       reason:(NSString *)reason;

/// Core of the completion path, split out of the delegate callback so a test
/// can drive it without a network: logs, deletes the staged file, posts ONE
/// notification iff the result is a failure, then calls the task's completion.
- (void)finishTaskWithDescription:(NSString *)taskDescription
                         response:(nullable NSURLResponse *)response
                            error:(nullable NSError *)error
                       completion:(nullable GLDropTaskCompletion)completion;

@end

NS_ASSUME_NONNULL_END
