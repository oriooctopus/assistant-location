#import "GLDropBackground.h"
#import "GLDropUploader.h"

#import <UserNotifications/UserNotifications.h>

NSString *const GLDropAppGroup = @"group.com.oliverullman.assistantlocation";
NSString *const GLDropSessionIdentifierPrefix = @"com.oliverullman.assistantlocation.drop.";

static void (^sLogHandler)(NSString *);

@interface GLDropBackground ()
@property(nonatomic, copy, readwrite) NSString *identifier;
@property(nonatomic, strong, readwrite) NSURLSession *session;
@property(nonatomic, copy, nullable) void (^backgroundCompletionHandler)(void);
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, GLDropTaskCompletion> *completions;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, void (^)(int64_t, int64_t)> *progressBlocks;
// Entered when a notification is handed to the system, left when it accepts
// it, so the app's completion handler is not called (letting iOS suspend the
// process) while a failure notification is still in flight.
@property(nonatomic, strong) dispatch_group_t pendingNotifications;
@end

@implementation GLDropBackground

+ (void (^)(NSString *))logHandler { return sLogHandler; }
+ (void)setLogHandler:(void (^)(NSString *))logHandler { sLogHandler = [logHandler copy]; }

static void GLDropLog(NSString *line) {
    if (sLogHandler) sLogHandler(line);
}

#pragma mark - Pure helpers

+ (BOOL)ownsSessionIdentifier:(NSString *)identifier {
    return [identifier hasPrefix:GLDropSessionIdentifierPrefix];
}

+ (NSURLSessionConfiguration *)configurationWithIdentifier:(NSString *)identifier {
    NSURLSessionConfiguration *config =
        [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:identifier];
    config.sharedContainerIdentifier = GLDropAppGroup;
    config.sessionSendsLaunchEvents = YES;
    config.discretionary = NO;
    return config;
}

+ (NSURL *)defaultStagingRoot {
    NSURL *container =
        [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:GLDropAppGroup];
    return [container URLByAppendingPathComponent:@"GLDropStaging" isDirectory:YES];
}

+ (NSURL *)moveFileAtURL:(NSURL *)source
                filename:(NSString *)filename
                  toRoot:(NSURL *)root
         taskDescription:(NSString **)taskDescription
                   error:(NSString **)error {
    // A "/" in the name would break the "<uuid>/<filename>" description.
    NSString *safeName = [filename stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    NSString *uuid = NSUUID.UUID.UUIDString;
    NSURL *dir = [root URLByAppendingPathComponent:uuid isDirectory:YES];
    NSError *fsError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:dir
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:&fsError]) {
        if (error) *error = [NSString stringWithFormat:@"could not create staging dir %@: %@", dir.path, fsError];
        return nil;
    }
    NSURL *dest = [dir URLByAppendingPathComponent:safeName];
    if (![NSFileManager.defaultManager moveItemAtURL:source toURL:dest error:&fsError]) {
        if (error) *error = [NSString stringWithFormat:@"could not move %@ into the group container: %@", source.path, fsError];
        return nil;
    }
    if (taskDescription) *taskDescription = [NSString stringWithFormat:@"%@/%@", uuid, safeName];
    return dest;
}

+ (NSString *)failureReasonForResponse:(NSURLResponse *)response error:(NSError *)error {
    if (error) {
        if ([error.domain isEqualToString:NSURLErrorDomain]) {
            switch (error.code) {
                case NSURLErrorNetworkConnectionLost: return @"connection lost";
                case NSURLErrorNotConnectedToInternet: return @"no internet connection";
                case NSURLErrorTimedOut: return @"timed out";
                case NSURLErrorCannotConnectToHost:
                case NSURLErrorCannotFindHost:
                case NSURLErrorDNSLookupFailed: return @"couldn't reach the server";
                case NSURLErrorDataNotAllowed: return @"data connection not allowed";
                case NSURLErrorCancelled: return @"cancelled";
                default: break;
            }
        }
        return error.localizedDescription;
    }
    if (![response isKindOfClass:[NSHTTPURLResponse class]]) return @"no response from server";
    NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
    if (status >= 200 && status <= 299) return nil;
    if (status == 401 || status == 403) return [NSString stringWithFormat:@"server rejected it (HTTP %ld)", (long)status];
    if (status == 413) return @"file too large (HTTP 413)";
    return [NSString stringWithFormat:@"server returned HTTP %ld", (long)status];
}

+ (NSString *)notificationTitle { return @"Upload failed"; }

+ (NSString *)notificationBodyForFilename:(NSString *)filename reason:(NSString *)reason {
    return [NSString stringWithFormat:@"%@: %@", filename, reason];
}

#pragma mark - Session

+ (instancetype)newUploadSession {
    return [[self alloc] initWithIdentifier:
        [GLDropSessionIdentifierPrefix stringByAppendingString:NSUUID.UUID.UUIDString]];
}

// Sessions reconnected by the app, kept alive until their events finish: the
// NSURLSession retains its delegate only until invalidated, and nothing else
// holds the GLDropBackground.
+ (NSMutableDictionary<NSString *, GLDropBackground *> *)liveReconnected {
    static NSMutableDictionary *live;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ live = [NSMutableDictionary dictionary]; });
    return live;
}

+ (instancetype)reconnectSessionWithIdentifier:(NSString *)identifier
                             completionHandler:(void (^)(void))completionHandler {
    GLDropBackground *drop = [[self alloc] initWithIdentifier:identifier];
    drop.backgroundCompletionHandler = completionHandler;
    @synchronized([self liveReconnected]) { [self liveReconnected][identifier] = drop; }
    (void)drop.session;  // creating it is what makes iOS deliver the pending callbacks
    GLDropLog([NSString stringWithFormat:@"bg-session reconnected id=%@", identifier]);
    return drop;
}

- (instancetype)initWithIdentifier:(NSString *)identifier {
    if ((self = [super init])) {
        _identifier = [identifier copy];
        _completions = [NSMutableDictionary dictionary];
        _progressBlocks = [NSMutableDictionary dictionary];
        _pendingNotifications = dispatch_group_create();
        _stagingRoot = [GLDropBackground defaultStagingRoot];
        _notifier = ^(NSString *identifier, NSString *title, NSString *body, void (^done)(void)) {
            UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
            content.title = title;
            content.body = body;
            content.sound = UNNotificationSound.defaultSound;
            // Same identifier per file: a repeat replaces instead of stacking.
            UNNotificationRequest *request =
                [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:nil];
            [UNUserNotificationCenter.currentNotificationCenter
                addNotificationRequest:request
                 withCompletionHandler:^(NSError *error) {
                if (error) GLDropLog([NSString stringWithFormat:@"bg-session notification error=%@", error]);
                done();
            }];
        };
    }
    return self;
}

- (NSURLSession *)session {
    @synchronized(self) {
        if (!_session) {
            _session = [NSURLSession sessionWithConfiguration:[GLDropBackground configurationWithIdentifier:self.identifier]
                                                     delegate:self
                                                delegateQueue:nil];
        }
        return _session;
    }
}

- (NSURLSessionUploadTask *)uploadStagedFileAtURL:(NSURL *)staged
                                  taskDescription:(NSString *)taskDescription
                                      contentType:(NSString *)contentType
                                       toEndpoint:(NSString *)endpoint
                                            token:(NSString *)token
                                         progress:(void (^)(int64_t, int64_t))progress
                                       completion:(GLDropTaskCompletion)completion {
    NSString *filename = [GLDropBackground filenameFromTaskDescription:taskDescription];
    NSMutableURLRequest *request = [GLDropUploader requestForEndpoint:endpoint
                                                             filename:filename
                                                          contentType:contentType
                                                                token:token];
    NSURLSessionUploadTask *task = [self.session uploadTaskWithRequest:request fromFile:staged];
    task.taskDescription = taskDescription;
    @synchronized(self) {
        if (completion) self.completions[@(task.taskIdentifier)] = [completion copy];
        if (progress) self.progressBlocks[@(task.taskIdentifier)] = [progress copy];
    }
    [task resume];
    return task;
}

+ (NSString *)filenameFromTaskDescription:(NSString *)description {
    NSRange slash = [description rangeOfString:@"/"];
    return slash.location == NSNotFound ? description : [description substringFromIndex:NSMaxRange(slash)];
}

- (void)postFailureNotificationWithIdentifier:(NSString *)identifier
                                     filename:(NSString *)filename
                                       reason:(NSString *)reason {
    dispatch_group_t group = self.pendingNotifications;
    dispatch_group_enter(group);
    self.notifier(identifier,
                  [GLDropBackground notificationTitle],
                  [GLDropBackground notificationBodyForFilename:filename reason:reason],
                  ^{ dispatch_group_leave(group); });
}

- (void)finishTaskWithDescription:(NSString *)taskDescription
                         response:(NSURLResponse *)response
                            error:(NSError *)error
                       completion:(GLDropTaskCompletion)completion {
    NSString *filename = [GLDropBackground filenameFromTaskDescription:taskDescription];
    NSString *reason = [GLDropBackground failureReasonForResponse:response error:error];
    GLDropLog([NSString stringWithFormat:@"bg-session task done id=%@ file=%@ %@", self.identifier, filename,
               reason ? [NSString stringWithFormat:@"failed=%@", reason] : @"ok"]);

    // The staged copy is single-use, success or failure.
    NSRange slash = [taskDescription rangeOfString:@"/"];
    if (slash.location != NSNotFound) {
        NSString *uuid = [taskDescription substringToIndex:slash.location];
        [NSFileManager.defaultManager removeItemAtURL:[self.stagingRoot URLByAppendingPathComponent:uuid]
                                                error:NULL];
    }

    if (reason) {
        [self postFailureNotificationWithIdentifier:[@"drop-failed-" stringByAppendingString:taskDescription]
                                           filename:filename
                                             reason:reason];
    }
    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(filename, reason); });
    }
}

#pragma mark - NSURLSessionDelegate

- (void)URLSession:(NSURLSession *)session
                        task:(NSURLSessionTask *)task
             didSendBodyData:(int64_t)bytesSent
              totalBytesSent:(int64_t)totalBytesSent
    totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
    void (^progress)(int64_t, int64_t);
    @synchronized(self) { progress = self.progressBlocks[@(task.taskIdentifier)]; }
    if (!progress) return;
    dispatch_async(dispatch_get_main_queue(), ^{ progress(totalBytesSent, totalBytesExpectedToSend); });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    GLDropTaskCompletion completion;
    @synchronized(self) {
        completion = self.completions[@(task.taskIdentifier)];
        [self.completions removeObjectForKey:@(task.taskIdentifier)];
        [self.progressBlocks removeObjectForKey:@(task.taskIdentifier)];
    }
    [self finishTaskWithDescription:task.taskDescription ?: @"unknown/unknown"
                           response:task.response
                              error:error
                         completion:completion];
}

- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    void (^handler)(void) = self.backgroundCompletionHandler;
    self.backgroundCompletionHandler = nil;
    GLDropLog([NSString stringWithFormat:@"bg-session events finished id=%@ hasHandler=%d", self.identifier, handler != nil]);
    if (!handler) return;
    dispatch_group_notify(self.pendingNotifications, dispatch_get_main_queue(), ^{
        handler();
        @synchronized([GLDropBackground liveReconnected]) {
            [[GLDropBackground liveReconnected] removeObjectForKey:self.identifier];
        }
        [session finishTasksAndInvalidate];
    });
}

@end
