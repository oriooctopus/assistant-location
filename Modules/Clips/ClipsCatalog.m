#import "ClipsCatalog.h"

static NSString *const kClipsErrorDomain = @"ClipsCatalog";

static BOOL ClipsMatches(NSString *pattern, NSString *s) {
    return [s rangeOfString:pattern options:NSRegularExpressionSearch].location != NSNotFound;
}

static NSString *const kIDPattern = @"^[a-z0-9][a-z0-9-]*\\z";
static NSString *const kFilePattern = @"^[A-Za-z0-9][A-Za-z0-9._-]*\\.m4a\\z";
static NSString *const kScorePattern = @"^[A-Za-z0-9][A-Za-z0-9._-]*\\.pdf\\z";

@implementation ClipsCatalog

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)clipsFromManifestData:(NSData *)data error:(NSError **)error {
    NSError *jsonError = nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    NSString *problem = nil;
    NSMutableArray *clips = [NSMutableArray array];
    if (!root) {
        problem = [NSString stringWithFormat:@"not JSON: %@", jsonError.localizedDescription];
    } else if (![root isKindOfClass:[NSArray class]]) {
        problem = [NSString stringWithFormat:@"top level is %@, not an array", NSStringFromClass([root class])];
    } else {
        NSMutableSet *seen = [NSMutableSet set];
        for (id item in (NSArray *)root) {
            if (![item isKindOfClass:[NSDictionary class]]) {
                problem = [NSString stringWithFormat:@"entry is %@, not an object", NSStringFromClass([item class])];
                break;
            }
            NSString *clipID = item[@"id"], *title = item[@"title"], *file = item[@"file"];
            if (![clipID isKindOfClass:[NSString class]] || !ClipsMatches(kIDPattern, clipID)) {
                problem = [NSString stringWithFormat:@"bad id %@", clipID];
                break;
            }
            if (![title isKindOfClass:[NSString class]] || title.length == 0) {
                problem = [NSString stringWithFormat:@"clip %@ has no title", clipID];
                break;
            }
            if (![file isKindOfClass:[NSString class]] || !ClipsMatches(kFilePattern, file)) {
                problem = [NSString stringWithFormat:@"clip %@ has bad file %@", clipID, file];
                break;
            }
            NSString *score = item[@"score"];
            if (score && (![score isKindOfClass:[NSString class]] || !ClipsMatches(kScorePattern, score))) {
                problem = [NSString stringWithFormat:@"clip %@ has bad score %@", clipID, score];
                break;
            }
            if ([seen containsObject:clipID]) {
                problem = [NSString stringWithFormat:@"duplicate id %@", clipID];
                break;
            }
            [seen addObject:clipID];
            [clips addObject:score ? @{@"id": clipID, @"title": title, @"file": file, @"score": score}
                                   : @{@"id": clipID, @"title": title, @"file": file}];
        }
    }
    if (problem) {
        if (error) {
            *error = [NSError errorWithDomain:kClipsErrorDomain code:1
                                     userInfo:@{NSLocalizedDescriptionKey: [@"Clips manifest: " stringByAppendingString:problem]}];
        }
        return nil;
    }
    return clips;
}

+ (NSString *)clipIDFromURL:(NSURL *)url {
    if (![url.scheme isEqualToString:@"overland"] || ![url.host isEqualToString:@"clips"]) return nil;
    NSString *path = url.path;
    if (![path hasPrefix:@"/"]) return nil;
    NSString *clipID = [path substringFromIndex:1];
    return ClipsMatches(kIDPattern, clipID) ? clipID : nil;
}

+ (NSString *)sectionReferenceFromURL:(NSURL *)url {
    if (![ClipsCatalog clipIDFromURL:url]) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"section"] && item.value.length) return item.value;
    }
    return nil;
}

+ (NSURL *)localURLForFile:(NSString *)file inDirectory:(NSURL *)directory {
    if (!ClipsMatches(kFilePattern, file)) {
        [NSException raise:NSInvalidArgumentException format:@"Clips: %@ is not a plain .m4a file name", file];
    }
    return [directory URLByAppendingPathComponent:file];
}

+ (NSURL *)localURLForScore:(NSString *)score inDirectory:(NSURL *)directory {
    if (!ClipsMatches(kScorePattern, score)) {
        [NSException raise:NSInvalidArgumentException format:@"Clips: %@ is not a plain .pdf file name", score];
    }
    return [directory URLByAppendingPathComponent:score];
}

@end
