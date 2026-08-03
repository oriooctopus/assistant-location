// Loading an image out of an NSItemProvider and POSTing its bytes to the
// location server's /drop endpoint, shared by the share extension and the
// app's Upload tab. Both get their items as NSItemProviders (the share sheet
// vends them directly, PHPickerViewController vends them per result), so the
// whole path below is common to both.
//
// Deliberately takes the endpoint and token as arguments rather than importing
// a config header: the extension bakes its values into ShareConfig.h and the
// app into BakedConfig.h, and this file has to compile into both targets.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// data/filename/contentType are non-nil on success; error is non-nil on failure.
typedef void (^GLDropLoadCompletion)(NSData *_Nullable data,
                                     NSString *_Nullable filename,
                                     NSString *_Nullable contentType,
                                     NSString *_Nullable error);

@interface GLDropUploader : NSObject

/// Prefers the original file representation so a PNG screenshot stays a PNG,
/// falling back to a re-encoded JPEG only when the provider cannot vend a file.
+ (void)loadImageFromProvider:(NSItemProvider *)provider
                        index:(NSUInteger)index
                   completion:(GLDropLoadCompletion)completion;

/// POSTs the raw bytes. completion gets nil on success, else a short message.
+ (void)uploadData:(NSData *)data
          filename:(NSString *)filename
       contentType:(NSString *)contentType
        toEndpoint:(NSString *)endpoint
             token:(NSString *)token
        completion:(void (^)(NSString *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
