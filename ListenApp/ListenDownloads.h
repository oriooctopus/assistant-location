// ListenDownloads: keeps the audio of recently played Listen items on disk so it
// plays offline (PROTOCOL.md `download` / `getDownloads`). Plain Foundation so the
// host-less SharedTests bundle can compile it. Local path mirrors the URL path:
// http://host:8315/audio/<id>/tts/12-clear.mp3 -> <root>/audio/<id>/tts/12-clear.mp3

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ListenDownloads : NSObject

+ (instancetype)shared;

/// "audio/<id>/<...>/<file>" for an http(s) URL whose path starts with /audio/ (or /<prefix>/audio/) and has
/// no empty, "." or ".." component (after percent-decoding); nil otherwise.
+ (nullable NSString *)relativePathForURL:(NSURL *)url;
/// `relativePath` under `root`.
+ (NSURL *)fileURLForRelativePath:(NSString *)relativePath root:(NSURL *)root;
/// nil when `items` is a valid download list ([{itemId:string, urls:[string]}], every url
/// accepted by relativePathForURL), else an error message.
+ (nullable NSString *)validateItems:(nullable id)items;
/// Application Support/ListenAudio, created and excluded from iCloud backup.
+ (NSURL *)defaultRoot;
/// The downloaded file for `remote` when it is on disk under the default root, else nil.
+ (nullable NSURL *)localURLForRemote:(NSURL *)remote;

/// Replaces the target set (items already validated by validateItems:): evicts audio of
/// items not in it, replaces the pending queue with its missing urls, starts downloading.
- (void)setItems:(NSArray<NSDictionary *> *)items;
/// {root, items:{itemId:{have,total,bytes}}, pending} where pending counts queued + in-flight.
- (NSDictionary *)status;

@end

NS_ASSUME_NONNULL_END
