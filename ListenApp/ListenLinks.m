#import "ListenLinks.h"

@implementation ListenLinks

+ (BOOL)shouldOpenExternally:(NSURL *)url pageURL:(NSURL *)pageURL isNewWindow:(BOOL)isNewWindow
            isLinkActivation:(BOOL)isLinkActivation {
    if (!url) return NO;
    if (isNewWindow) return YES;
    if (!isLinkActivation) return NO;
    NSString *scheme = url.scheme.lowercaseString;
    if ([scheme isEqualToString:@"file"]) return NO;
    BOOL http = [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
    BOOL sameHost = http && url.host && [url.host caseInsensitiveCompare:pageURL.host ?: @""] == NSOrderedSame;
    return !sameHost;
}

@end
