#import "GLDropUploader.h"

#import <UIKit/UIKit.h>

static NSString *const kImageType = @"public.image";

@implementation GLDropUploader

#pragma mark - Loading

+ (void)loadImageFromProvider:(NSItemProvider *)provider
                        index:(NSUInteger)index
                   completion:(GLDropLoadCompletion)completion {
    [provider loadFileRepresentationForTypeIdentifier:kImageType
                                    completionHandler:^(NSURL *url, NSError *error) {
        // The temp file is only valid for the duration of this block.
        NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
        if (data.length > 0) {
            NSString *name = [self filenameForURL:url provider:provider index:index];
            completion(data, name, [self contentTypeForFilename:name], nil);
            return;
        }
        [self loadJPEGFromProvider:provider index:index completion:completion];
    }];
}

+ (void)loadJPEGFromProvider:(NSItemProvider *)provider
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
        completion(jpeg, name, @"image/jpeg", nil);
    }];
}

+ (NSString *)filenameForURL:(NSURL *)url
                    provider:(NSItemProvider *)provider
                       index:(NSUInteger)index {
    NSString *name = url.lastPathComponent;
    if (name.length > 0 && name.pathExtension.length > 0) return name;
    NSString *suggested = provider.suggestedName;
    if (suggested.length > 0 && suggested.pathExtension.length > 0) return suggested;
    NSString *ext = name.pathExtension.length > 0 ? name.pathExtension : @"png";
    return [NSString stringWithFormat:@"screenshot-%lu.%@", (unsigned long)(index + 1), ext];
}

+ (NSString *)contentTypeForFilename:(NSString *)filename {
    NSString *ext = filename.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) return @"image/jpeg";
    if ([ext isEqualToString:@"heic"]) return @"image/heic";
    if ([ext isEqualToString:@"gif"]) return @"image/gif";
    return @"image/png";
}

#pragma mark - Upload

+ (void)uploadData:(NSData *)data
          filename:(NSString *)filename
       contentType:(NSString *)contentType
        toEndpoint:(NSString *)endpoint
             token:(NSString *)token
        completion:(void (^)(NSString *error))completion {
    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 60;
    [request setValue:[NSString stringWithFormat:@"Bearer %@", token]
        forHTTPHeaderField:@"Authorization"];
    [request setValue:filename forHTTPHeaderField:@"X-Filename"];
    [request setValue:contentType forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = data;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *body, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(error.localizedDescription);
            return;
        }
        NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
        if (status < 200 || status > 299) {
            completion([NSString stringWithFormat:@"HTTP %ld", (long)status]);
            return;
        }
        completion(nil);
    }];
    [task resume];
}

@end
