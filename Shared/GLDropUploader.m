#import "GLDropUploader.h"

#import <UIKit/UIKit.h>
#import <MobileCoreServices/MobileCoreServices.h>

static NSString *const kImageType = @"public.image";
static NSString *const kMovieType = @"public.movie";
static NSString *const kAudioType = @"public.audio";
static NSString *const kFileURLType = @"public.file-url";
static NSString *const kURLType = @"public.url";
static NSString *const kTextType = @"public.text";
static NSString *const kDataType = @"public.data";

@implementation GLDropUploader

#pragma mark - Loading

/// Mirrors the NSExtensionActivationRule predicate in ShareToDesktop's
/// Info.plist: keep the two in step, or the sheet offers a share the code
/// then refuses (or the reverse).
+ (GLDropKind)kindOfProvider:(NSItemProvider *)provider {
    if ([provider hasItemConformingToTypeIdentifier:kImageType]) return GLDropKindImage;
    if ([provider hasItemConformingToTypeIdentifier:kMovieType]) return GLDropKindMovie;
    if ([provider hasItemConformingToTypeIdentifier:kAudioType]) return GLDropKindAudio;
    // A file:// URL is a file whatever it points at; checked before the
    // public.url exclusion below because public.file-url conforms to it.
    if ([provider hasItemConformingToTypeIdentifier:kFileURLType]) return GLDropKindFile;
    // A web link or a selected text snippet also conforms to public.data,
    // and neither is a file worth dropping.
    if ([provider hasItemConformingToTypeIdentifier:kURLType] ||
        [provider hasItemConformingToTypeIdentifier:kTextType]) {
        return GLDropKindUnsupported;
    }
    // Everything else the Files app or a mail attachment hands over is typed
    // by its content (com.adobe.pdf, public.zip-archive, ...) and vends a
    // file representation under that type.
    if ([provider hasItemConformingToTypeIdentifier:kDataType]) return GLDropKindFile;
    return GLDropKindUnsupported;
}

/// The concrete registered identifier to ask a GLDropKindFile provider for.
+ (nullable NSString *)dataTypeIdentifierForProvider:(NSItemProvider *)provider {
    for (NSString *type in provider.registeredTypeIdentifiers) {
        if (UTTypeConformsTo((__bridge CFStringRef)type, (__bridge CFStringRef)kDataType)) return type;
    }
    return nil;
}

+ (BOOL)providerIsSupported:(NSItemProvider *)provider {
    return [self kindOfProvider:provider] != GLDropKindUnsupported;
}

+ (void)loadItemFromProvider:(NSItemProvider *)provider
                       index:(NSUInteger)index
                  completion:(GLDropLoadCompletion)completion {
    GLDropKind kind = [self kindOfProvider:provider];
    if (kind == GLDropKindUnsupported) {
        completion(nil, nil, nil, @"unsupported item");
        return;
    }
    if (kind == GLDropKindFile) {
        [self stageGenericFileFromProvider:provider index:index completion:completion];
        return;
    }

    NSString *type = kind == GLDropKindMovie ? kMovieType
                   : kind == GLDropKindAudio ? kAudioType
                                             : kImageType;
    [provider loadFileRepresentationForTypeIdentifier:type
                                    completionHandler:^(NSURL *url, NSError *error) {
        // The vended URL is only valid for the lifetime of this block, so the
        // file has to be copied out now — the upload happens later and would
        // otherwise find nothing there. Copying is also what keeps this off
        // the NSData path: nothing is ever held in memory.
        if (url) {
            NSString *name = [self filenameForURL:url provider:provider index:index kind:kind];
            NSURL *staged = [self stageFileAtURL:url preferredName:name];
            if (staged) {
                completion(staged, name, [self contentTypeForFilename:name], nil);
                return;
            }
        }
        if (kind != GLDropKindImage) {
            // No salvage path for video or audio: unlike a still, neither can
            // be re-encoded from an in-memory object.
            completion(nil, nil, nil,
                       error.localizedDescription ?: (kind == GLDropKindMovie
                                                          ? @"could not read video"
                                                          : @"could not read recording"));
            return;
        }
        [self stageJPEGFromProvider:provider index:index completion:completion];
    }];
}

/// Anything that is neither still, video nor audio. Two shapes arrive here:
/// an item typed by its content (com.adobe.pdf from Files), which vends a
/// temp copy under that type exactly like an image does, and a bare file://
/// URL, where the provider hands over the URL itself — possibly
/// security-scoped, so access is opened around the copy.
+ (void)stageGenericFileFromProvider:(NSItemProvider *)provider
                               index:(NSUInteger)index
                          completion:(GLDropLoadCompletion)completion {
    if (![provider hasItemConformingToTypeIdentifier:kFileURLType]) {
        NSString *type = [self dataTypeIdentifierForProvider:provider];
        if (!type) {
            completion(nil, nil, nil, @"no data type registered");
            return;
        }
        [provider loadFileRepresentationForTypeIdentifier:type
                                        completionHandler:^(NSURL *url, NSError *error) {
            NSString *name = url ? [self filenameForURL:url provider:provider index:index kind:GLDropKindFile] : nil;
            NSURL *staged = url ? [self stageFileAtURL:url preferredName:name] : nil;
            if (!staged) {
                completion(nil, nil, nil,
                           [NSString stringWithFormat:@"could not read %@: %@", type,
                                                       error.localizedDescription ?: @"no file vended"]);
                return;
            }
            completion(staged, name, [self contentTypeForFilename:name], nil);
        }];
        return;
    }
    [provider loadItemForTypeIdentifier:kFileURLType
                                options:nil
                      completionHandler:^(id<NSSecureCoding> item, NSError *error) {
        NSURL *url = [(id)item isKindOfClass:[NSURL class]] ? (NSURL *)item : nil;
        if (!url) {
            NSString *reason = error.localizedDescription
                ?: [NSString stringWithFormat:@"file URL item was %@",
                                               item ? NSStringFromClass([(id)item class]) : @"nil"];
            completion(nil, nil, nil, [NSString stringWithFormat:@"could not read file URL: %@", reason]);
            return;
        }
        BOOL scoped = [url startAccessingSecurityScopedResource];
        NSString *name = [self filenameForURL:url provider:provider index:index kind:GLDropKindFile];
        NSURL *staged = [self stageFileAtURL:url preferredName:name];
        if (scoped) [url stopAccessingSecurityScopedResource];
        if (!staged) {
            completion(nil, nil, nil, @"could not read file URL: copy failed");
            return;
        }
        completion(staged, name, [self contentTypeForFilename:name], nil);
    }];
}

/// Copies the provider's temp file into our own temp directory, returning the
/// new location (or nil if the copy failed).
+ (nullable NSURL *)stageFileAtURL:(NSURL *)url preferredName:(NSString *)name {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *dir = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
    NSURL *dest = [dir URLByAppendingPathComponent:
                        [NSString stringWithFormat:@"drop-%@-%@",
                                                   NSUUID.UUID.UUIDString, name]];
    [fm removeItemAtURL:dest error:NULL];
    NSError *copyError = nil;
    if (![fm copyItemAtURL:url toURL:dest error:&copyError]) return nil;

    NSNumber *size = nil;
    [dest getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
    if (size.longLongValue <= 0) {
        [fm removeItemAtURL:dest error:NULL];
        return nil;
    }
    return dest;
}

/// Images only: when the provider cannot vend a file, re-encode whatever
/// UIImage it can produce and stage that instead.
+ (void)stageJPEGFromProvider:(NSItemProvider *)provider
                        index:(NSUInteger)index
                   completion:(GLDropLoadCompletion)completion {
    [provider loadObjectOfClass:[UIImage class]
              completionHandler:^(UIImage *image, NSError *error) {
        if (![image isKindOfClass:[UIImage class]]) {
            completion(nil, nil, nil, error.localizedDescription ?: @"could not read image");
            return;
        }
        NSData *jpeg = UIImageJPEGRepresentation(image, 0.9);
        if (!jpeg) {
            completion(nil, nil, nil, @"could not encode image");
            return;
        }
        NSString *name =
            [NSString stringWithFormat:@"screenshot-%lu.jpg", (unsigned long)(index + 1)];
        NSURL *dest = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
            URLByAppendingPathComponent:[NSString stringWithFormat:@"drop-%@-%@",
                                                                   NSUUID.UUID.UUIDString, name]];
        if (![jpeg writeToURL:dest atomically:YES]) {
            completion(nil, nil, nil, @"could not stage image");
            return;
        }
        completion(dest, name, @"image/jpeg", nil);
    }];
}

+ (NSString *)filenameForURL:(NSURL *)url
                    provider:(NSItemProvider *)provider
                       index:(NSUInteger)index
                        kind:(GLDropKind)kind {
    NSString *stem, *fallbackExt;
    switch (kind) {
        case GLDropKindMovie: stem = @"video"; fallbackExt = @"mov"; break;
        case GLDropKindAudio: stem = @"recording"; fallbackExt = @"m4a"; break;
        case GLDropKindFile: stem = @"file"; fallbackExt = @"bin"; break;
        default: stem = @"screenshot"; fallbackExt = @"png"; break;
    }
    // loadFileRepresentation vends its temp file named after the UTI's
    // description ("Apple MPEG-4 audio.m4a"), not the item's real name, so
    // the provider's own suggestedName (set from the original filename) has
    // to win over url.lastPathComponent whenever it's present.
    NSString *suggested = provider.suggestedName;
    if (suggested.length > 0) {
        if (suggested.pathExtension.length > 0) return suggested;
        NSString *ext = url.pathExtension.length > 0 ? url.pathExtension : fallbackExt;
        return [NSString stringWithFormat:@"%@.%@", suggested, ext];
    }
    NSString *name = url.lastPathComponent;
    if (name.length > 0 && name.pathExtension.length > 0) return name;
    NSString *ext = name.pathExtension.length > 0 ? name.pathExtension : fallbackExt;
    return [NSString stringWithFormat:@"%@-%lu.%@", stem, (unsigned long)(index + 1), ext];
}

+ (NSString *)contentTypeForFilename:(NSString *)filename {
    static NSDictionary<NSString *, NSString *> *byExt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        byExt = @{
            @"jpg" : @"image/jpeg",      @"jpeg" : @"image/jpeg",
            @"png" : @"image/png",       @"heic" : @"image/heic",
            @"heif" : @"image/heif",     @"gif" : @"image/gif",
            @"mov" : @"video/quicktime", @"mp4" : @"video/mp4",
            @"m4v" : @"video/x-m4v",
            @"m4a" : @"audio/mp4",       @"mp3" : @"audio/mpeg",
            @"wav" : @"audio/wav",       @"aac" : @"audio/aac",
            @"caf" : @"audio/x-caf",     @"aiff" : @"audio/aiff",
            @"pdf" : @"application/pdf", @"txt" : @"text/plain",
            @"md" : @"text/markdown",    @"zip" : @"application/zip",
        };
    });
    return byExt[filename.pathExtension.lowercaseString] ?: @"application/octet-stream";
}

#pragma mark - Upload

/// Shared request shape for both upload paths.
+ (NSMutableURLRequest *)requestForEndpoint:(NSString *)endpoint
                                   filename:(NSString *)filename
                                contentType:(NSString *)contentType
                                      token:(NSString *)token {
    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
    request.HTTPMethod = @"POST";
    // A minute is plenty for a photo and nowhere near enough for a video on a
    // phone uplink, where timing out discards the entire transfer.
    request.timeoutInterval = 30 * 60;
    [request setValue:[NSString stringWithFormat:@"Bearer %@", token]
        forHTTPHeaderField:@"Authorization"];
    [request setValue:filename forHTTPHeaderField:@"X-Filename"];
    [request setValue:contentType forHTTPHeaderField:@"Content-Type"];
    return request;
}

/// Maps a finished task to nil-or-message, so both paths report failures the
/// same way.
+ (nullable NSString *)errorForResponse:(NSURLResponse *)response error:(NSError *)error {
    if (error) return error.localizedDescription;
    NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
    if (status < 200 || status > 299) {
        return [NSString stringWithFormat:@"HTTP %ld", (long)status];
    }
    return nil;
}

+ (void)uploadData:(NSData *)data
          filename:(NSString *)filename
       contentType:(NSString *)contentType
        toEndpoint:(NSString *)endpoint
             token:(NSString *)token
        completion:(void (^)(NSString *error))completion {
    NSMutableURLRequest *request = [self requestForEndpoint:endpoint
                                                   filename:filename
                                                contentType:contentType
                                                      token:token];
    request.HTTPBody = data;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *body, NSURLResponse *response, NSError *error) {
        completion([self errorForResponse:response error:error]);
    }];
    [task resume];
}

+ (void)uploadFileAtURL:(NSURL *)fileURL
               filename:(NSString *)filename
            contentType:(NSString *)contentType
             toEndpoint:(NSString *)endpoint
                  token:(NSString *)token
             completion:(void (^)(NSString *error))completion {
    NSMutableURLRequest *request = [self requestForEndpoint:endpoint
                                                   filename:filename
                                                contentType:contentType
                                                      token:token];

    void (^finish)(NSString *) = ^(NSString *error) {
        [NSFileManager.defaultManager removeItemAtURL:fileURL error:NULL];
        completion(error);
    };

    // fromFile: streams off disk rather than materialising the body, which is
    // the whole reason this path is file-based.
    NSURLSessionUploadTask *task = [[NSURLSession sharedSession]
        uploadTaskWithRequest:request
                     fromFile:fileURL
            completionHandler:^(NSData *body, NSURLResponse *response, NSError *error) {
        finish([self errorForResponse:response error:error]);
    }];
    [task resume];
}

@end
