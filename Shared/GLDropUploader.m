#import "GLDropUploader.h"

#import <UIKit/UIKit.h>

static NSString *const kImageType = @"public.image";
static NSString *const kMovieType = @"public.movie";

@implementation GLDropUploader

#pragma mark - Loading

+ (BOOL)providerIsMovie:(NSItemProvider *)provider {
    return [provider hasItemConformingToTypeIdentifier:kMovieType];
}

+ (void)loadItemFromProvider:(NSItemProvider *)provider
                       index:(NSUInteger)index
                  completion:(GLDropLoadCompletion)completion {
    BOOL isMovie = [self providerIsMovie:provider];
    NSString *type = isMovie ? kMovieType : kImageType;

    [provider loadFileRepresentationForTypeIdentifier:type
                                    completionHandler:^(NSURL *url, NSError *error) {
        // The vended URL is only valid for the lifetime of this block, so the
        // file has to be copied out now — the upload happens later and would
        // otherwise find nothing there. Copying is also what keeps this off
        // the NSData path: nothing is ever held in memory.
        if (url) {
            NSString *name = [self filenameForURL:url provider:provider index:index isMovie:isMovie];
            NSURL *staged = [self stageFileAtURL:url preferredName:name];
            if (staged) {
                completion(staged, name, [self contentTypeForFilename:name], nil);
                return;
            }
        }
        if (isMovie) {
            // No salvage path for video: unlike a still, it cannot be
            // re-encoded from an in-memory object.
            completion(nil, nil, nil,
                       error.localizedDescription ?: @"could not read video");
            return;
        }
        [self stageJPEGFromProvider:provider index:index completion:completion];
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
                     isMovie:(BOOL)isMovie {
    NSString *name = url.lastPathComponent;
    if (name.length > 0 && name.pathExtension.length > 0) return name;
    NSString *suggested = provider.suggestedName;
    if (suggested.length > 0 && suggested.pathExtension.length > 0) return suggested;
    NSString *fallbackExt = isMovie ? @"mov" : @"png";
    NSString *ext = name.pathExtension.length > 0 ? name.pathExtension : fallbackExt;
    NSString *stem = isMovie ? @"video" : @"screenshot";
    return [NSString stringWithFormat:@"%@-%lu.%@", stem, (unsigned long)(index + 1), ext];
}

+ (NSString *)contentTypeForFilename:(NSString *)filename {
    NSString *ext = filename.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) return @"image/jpeg";
    if ([ext isEqualToString:@"heic"]) return @"image/heic";
    if ([ext isEqualToString:@"heif"]) return @"image/heif";
    if ([ext isEqualToString:@"gif"]) return @"image/gif";
    if ([ext isEqualToString:@"mov"]) return @"video/quicktime";
    if ([ext isEqualToString:@"mp4"]) return @"video/mp4";
    if ([ext isEqualToString:@"m4v"]) return @"video/x-m4v";
    return @"image/png";
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
