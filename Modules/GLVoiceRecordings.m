#import "GLVoiceRecordings.h"

static NSString *const kPrefix = @"session-voice-";
static NSString *const kSuffix = @".m4a";
static NSString *const kErrorDomain = @"GLVoiceRecordings";

@implementation GLVoiceRecordings

+ (NSURL *)defaultDirectory {
    NSURL *support = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [support URLByAppendingPathComponent:@"VoiceRecordings" isDirectory:YES];
}

+ (NSURL *)newRecordingURLInDirectory:(NSURL *)directory error:(NSError **)error {
    if (![[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    return [directory URLByAppendingPathComponent:[NSString stringWithFormat:@"%@%@%@", kPrefix, NSUUID.UUID.UUIDString, kSuffix]];
}

+ (NSString *)enqueueRecordingAtURL:(NSURL *)url
                             outbox:(GLDurableOutbox *)outbox
                               lang:(NSString *)lang
                           launchId:(NSString *)launchId
                          recovered:(BOOL)recovered
                              error:(NSError **)error {
    NSData *audio = [NSData dataWithContentsOfURL:url options:0 error:error];
    if (!audio) return nil;
    if (audio.length == 0) {
        if (error) *error = [NSError errorWithDomain:kErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: @"the recording file is empty"}];
        return nil;
    }
    NSString *itemID = [outbox enqueueKind:@"session-voice"
                                      // Baked into the queued item's path so audio recorded offline still gets the
                                      // code-switching transcriber on replay.
                                      path:([lang isEqual:@"multi"] ? @"/sessions/transcribe?lang=multi" : @"/sessions/transcribe")
                                   headers:@{@"Content-Type": @"audio/m4a"}
                                      body:audio
                                      meta:@{@"launchId": launchId ?: @"", @"recovered": @(recovered)}
                                keepResult:YES
                          acceptedStatuses:@[@422]
                            retryTransient:YES
                                     error:error];
    if (!itemID) return nil;
    [[NSFileManager defaultManager] removeItemAtURL:url error:NULL];
    return itemID;
}

+ (NSUInteger)recoverRecordingsInDirectory:(NSURL *)directory outbox:(GLDurableOutbox *)outbox {
    NSArray<NSURL *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:directory includingPropertiesForKeys:nil options:0 error:NULL];
    NSUInteger queued = 0;
    for (NSURL *file in files) {
        NSString *name = file.lastPathComponent;
        if (![name hasPrefix:kPrefix] || ![name hasSuffix:kSuffix]) continue;
        NSError *error = nil;
        if ([self enqueueRecordingAtURL:file outbox:outbox lang:nil launchId:nil recovered:YES error:&error]) {
            queued++;
        } else if ([error.domain isEqualToString:kErrorDomain]) {
            [[NSFileManager defaultManager] removeItemAtURL:file error:NULL]; // an empty recording has nothing to keep
        } else {
            NSLog(@"GLVoiceRecordings: could not queue %@, leaving it for the next launch: %@", name, error.localizedDescription);
        }
    }
    return queued;
}

@end
