// Loading a shared item out of an NSItemProvider and POSTing its bytes to the
// location server's /drop endpoint, shared by the share extension and the
// app's Upload tab. Both get their items as NSItemProviders (the share sheet
// vends them directly, PHPickerViewController vends them per result), so the
// whole path below is common to both.
//
// Deliberately takes the endpoint and token as arguments rather than importing
// a config header: the extension bakes its values into ShareConfig.h and the
// app into BakedConfig.h, and this file has to compile into both targets.
//
// File-based rather than NSData-based, because of video. A share extension is
// given a far smaller memory allowance than a normal app, and a phone video is
// easily hundreds of megabytes — reading one into NSData and handing that to
// HTTPBody holds it twice over and gets the extension killed outright.
// Staging to a temp file and streaming it with an upload task keeps memory
// flat however large the item is.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// fileURL/filename/contentType are non-nil on success; error is non-nil on
/// failure. The staged file belongs to the caller, and -uploadFileAtURL:...
/// deletes it once the upload finishes.
typedef void (^GLDropLoadCompletion)(NSURL *_Nullable fileURL,
                                     NSString *_Nullable filename,
                                     NSString *_Nullable contentType,
                                     NSString *_Nullable error);

@interface GLDropUploader : NSObject

/// YES if the provider carries a movie rather than a still image.
+ (BOOL)providerIsMovie:(NSItemProvider *)provider;

/// Stages an image or video from the provider into a temp file.
///
/// Prefers the original file representation so a PNG screenshot stays a PNG
/// and a video keeps its container, falling back to a re-encoded JPEG only
/// when the provider cannot vend a file — and only for images, since there is
/// no equivalent salvage path for a movie.
+ (void)loadItemFromProvider:(NSItemProvider *)provider
                       index:(NSUInteger)index
                  completion:(GLDropLoadCompletion)completion;

/// Streams the staged file to the endpoint and then DELETES it — it is meant
/// for the throwaway temp file that -loadItemFromProvider:... produces. Do not
/// point it at a file you still need; use -uploadData:... for that.
+ (void)uploadFileAtURL:(NSURL *)fileURL
               filename:(NSString *)filename
            contentType:(NSString *)contentType
             toEndpoint:(NSString *)endpoint
                  token:(NSString *)token
             completion:(void (^)(NSString *_Nullable error))completion;

/// POSTs bytes already in memory, leaving no file behind to clean up. Right
/// for small payloads a caller has produced itself, and for callers that must
/// keep their source file (AutoJournal holds its recording back for retry).
/// Anything phone-camera sized should go through the file path above instead.
+ (void)uploadData:(NSData *)data
          filename:(NSString *)filename
       contentType:(NSString *)contentType
        toEndpoint:(NSString *)endpoint
             token:(NSString *)token
        completion:(void (^)(NSString *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
