// Pure Foundation helpers for the Clips tab (compiled into SharedTests too):
// manifest parsing, deep-link parsing, cache file naming.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ClipsCatalog : NSObject

/// Parses the server manifest (a JSON array of {id, title, file, optional score})
/// into an array of dictionaries with those string keys. Returns nil
/// with a descriptive `error` when the data is not that shape.
+ (nullable NSArray<NSDictionary<NSString *, NSString *> *> *)clipsFromManifestData:(NSData *)data
                                                                               error:(NSError **)error;

/// The clip id in an `overland://clips/<id>` URL, or nil for any other URL.
+ (nullable NSString *)clipIDFromURL:(NSURL *)url;

/// The `section` query value in an `overland://clips/<id>?section=<n or id>` URL, or nil when absent.
+ (nullable NSString *)sectionReferenceFromURL:(NSURL *)url;

/// `directory`/`file`. Raises when `file` is not a plain *.m4a file name.
+ (NSURL *)localURLForFile:(NSString *)file inDirectory:(NSURL *)directory;

/// `directory`/`score`. Raises when `score` is not a plain *.pdf file name.
+ (NSURL *)localURLForScore:(NSString *)score inDirectory:(NSURL *)directory;

@end

NS_ASSUME_NONNULL_END
