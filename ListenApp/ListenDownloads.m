#import "ListenDownloads.h"

#import "GLLog.h"

@implementation ListenDownloads {
    NSURL *_root;
    NSURLSession *_session;
    NSArray<NSDictionary *> *_items;    // last accepted target set
    NSMutableArray<NSURL *> *_pending;  // queued, not yet started
    NSSet<NSString *> *_wanted;         // absoluteString of every url in _items
    NSString *_inflight;                // absoluteString of the running download, or nil
}

+ (instancetype)shared {
    static ListenDownloads *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[ListenDownloads alloc] init]; });
    return shared;
}

+ (NSString *)relativePathForURL:(NSURL *)url {
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqual:@"http"] && ![scheme isEqual:@"https"]) return nil;
    NSString *path = url.path;
    if (![path hasPrefix:@"/audio/"]) return nil;
    NSArray<NSString *> *parts = [[path substringFromIndex:1] componentsSeparatedByString:@"/"];
    if (parts.count < 3) return nil;
    for (NSString *part in parts) {
        if (part.length == 0 || [part isEqual:@"."] || [part isEqual:@".."] || [part containsString:@"\\"]) return nil;
    }
    return [parts componentsJoinedByString:@"/"];
}

+ (NSURL *)fileURLForRelativePath:(NSString *)relativePath root:(NSURL *)root {
    return [root URLByAppendingPathComponent:relativePath];
}

+ (NSString *)validateItems:(id)items {
    if (![items isKindOfClass:[NSArray class]]) return @"items: expected an array";
    for (id item in items) {
        if (![item isKindOfClass:[NSDictionary class]]) return @"items: each item must be an object";
        id itemId = item[@"itemId"], urls = item[@"urls"];
        if (![itemId isKindOfClass:[NSString class]] || [(NSString *)itemId length] == 0) return @"items: itemId must be a non-empty string";
        if (![urls isKindOfClass:[NSArray class]]) return [NSString stringWithFormat:@"items: urls of %@ must be an array", itemId];
        for (id u in urls) {
            if (![u isKindOfClass:[NSString class]]) return [NSString stringWithFormat:@"items: urls of %@ must be strings", itemId];
            NSURL *url = [NSURL URLWithString:u];
            if (!url || ![self relativePathForURL:url]) return [NSString stringWithFormat:@"items: url %@ must be http(s) with a path /audio/<id>/... and no ..", u];
        }
    }
    return nil;
}

+ (NSURL *)defaultRoot {
    static NSURL *root;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSError *error = nil;
        NSURL *support = [[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory
                                                                inDomain:NSUserDomainMask
                                                       appropriateForURL:nil
                                                                  create:YES
                                                                   error:&error];
        if (!support) {
            GLLog(@"no Application Support directory: %@", error);
            return;
        }
        NSURL *dir = [support URLByAppendingPathComponent:@"ListenAudio" isDirectory:YES];
        if (![[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:&error]) {
            GLLog(@"create %@ failed: %@", dir.path, error);
            return;
        }
        if (![dir setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&error]) {
            GLLog(@"exclude %@ from backup failed: %@", dir.path, error);
        }
        root = dir;
    });
    return root;
}

+ (NSURL *)localURLForRemote:(NSURL *)remote {
    NSString *relative = [self relativePathForURL:remote];
    NSURL *root = [self defaultRoot];
    if (!relative || !root) return nil;
    NSURL *file = [self fileURLForRelativePath:relative root:root];
    return [[NSFileManager defaultManager] fileExistsAtPath:file.path] ? file : nil;
}

- (instancetype)init {
    if ((self = [super init])) {
        _root = [ListenDownloads defaultRoot];
        _items = @[];
        _pending = [NSMutableArray array];
        _wanted = [NSSet set];
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 180;   // clear clips can be generated server-side on GET
        config.timeoutIntervalForResource = 3600; // a full episode
        _session = [NSURLSession sessionWithConfiguration:config];
    }
    return self;
}

- (void)setItems:(NSArray<NSDictionary *> *)items {
    if (!_root) {
        GLLog(@"download ignored: no storage root");
        return;
    }
    @synchronized (self) {
        _items = [items copy];
        NSMutableSet<NSString *> *wanted = [NSMutableSet set];
        NSMutableSet<NSString *> *keepDirs = [NSMutableSet set];
        NSMutableArray<NSURL *> *ordered = [NSMutableArray array];
        for (NSDictionary *item in items) {
            [keepDirs addObject:item[@"itemId"]];
            for (NSString *u in item[@"urls"]) {
                NSURL *url = [NSURL URLWithString:u];
                if ([wanted containsObject:url.absoluteString]) continue;
                [wanted addObject:url.absoluteString];
                [keepDirs addObject:[ListenDownloads relativePathForURL:url].pathComponents[1]];
                [ordered addObject:url];
            }
        }
        _wanted = wanted;
        [self evictExcept:keepDirs];
        [_pending removeAllObjects];
        for (NSURL *url in ordered) {
            if ([url.absoluteString isEqual:_inflight]) continue;
            NSURL *file = [ListenDownloads fileURLForRelativePath:[ListenDownloads relativePathForURL:url] root:_root];
            if ([[NSFileManager defaultManager] fileExistsAtPath:file.path]) continue;
            [_pending addObject:url];
        }
        GLLog(@"download: %lu items, %lu queued, in flight %@", (unsigned long)items.count, (unsigned long)_pending.count, _inflight ?: @"none");
        [self startNext];
    }
}

/// Deletes <root>/audio/<dir> for every dir not in `keepDirs`. Caller holds the lock.
- (void)evictExcept:(NSSet<NSString *> *)keepDirs {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *audio = [_root URLByAppendingPathComponent:@"audio" isDirectory:YES];
    NSError *error = nil;
    if (![fm fileExistsAtPath:audio.path]) return;
    NSArray<NSString *> *dirs = [fm contentsOfDirectoryAtPath:audio.path error:&error];
    if (!dirs) {
        GLLog(@"list %@ failed: %@", audio.path, error);
        return;
    }
    for (NSString *dir in dirs) {
        if ([keepDirs containsObject:dir]) continue;
        if ([fm removeItemAtURL:[audio URLByAppendingPathComponent:dir] error:&error]) {
            GLLog(@"evicted %@", dir);
        } else {
            GLLog(@"evict %@ failed: %@", dir, error);
        }
    }
}

/// Starts the next queued download if none is running. Caller holds the lock.
- (void)startNext {
    if (_inflight || _pending.count == 0) return;
    NSURL *url = _pending.firstObject;
    [_pending removeObjectAtIndex:0];
    _inflight = url.absoluteString;
    GLLog(@"download start %@", url.absoluteString);
    NSURLSessionDownloadTask *task = [_session downloadTaskWithURL:url completionHandler:^(NSURL *tmp, NSURLResponse *response, NSError *error) {
        // `tmp` is deleted when this block returns, so the move happens here.
        [self finishURL:url tmp:tmp response:response error:error];
    }];
    [task resume];
}

- (void)finishURL:(NSURL *)url tmp:(NSURL *)tmp response:(NSURLResponse *)response error:(NSError *)error {
    @synchronized (self) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : -1;
        if (error) {
            GLLog(@"download failed %@: %@", url.absoluteString, error);
        } else if (status < 200 || status > 299) {
            GLLog(@"download failed %@: HTTP status %ld", url.absoluteString, (long)status);
        } else if (![_wanted containsObject:url.absoluteString]) {
            GLLog(@"download dropped %@: no longer wanted", url.absoluteString);
        } else {
            NSError *attrError = nil;
            NSDictionary *attrs = [fm attributesOfItemAtPath:tmp.path error:&attrError];
            if (!attrs) {
                GLLog(@"download failed %@: cannot stat temp file: %@", url.absoluteString, attrError);
            } else if ([attrs fileSize] == 0) {
                GLLog(@"download failed %@: empty body (HTTP %ld)", url.absoluteString, (long)status);
            } else {
                NSURL *dest = [ListenDownloads fileURLForRelativePath:[ListenDownloads relativePathForURL:url] root:_root];
                NSError *moveError = nil;
                BOOL ok = [fm createDirectoryAtURL:[dest URLByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:&moveError];
                if (ok && [fm fileExistsAtPath:dest.path]) ok = [fm removeItemAtURL:dest error:&moveError];
                if (ok) ok = [fm moveItemAtURL:tmp toURL:dest error:&moveError];
                if (ok) {
                    GLLog(@"download saved %@ (%llu bytes)", dest.path, [attrs fileSize]);
                } else {
                    GLLog(@"download failed %@: cannot save: %@", url.absoluteString, moveError);
                }
            }
        }
        _inflight = nil;
        [self startNext];
    }
}

- (NSDictionary *)status {
    @synchronized (self) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSMutableDictionary *items = [NSMutableDictionary dictionary];
        for (NSDictionary *item in _items) {
            NSInteger have = 0, total = 0;
            unsigned long long bytes = 0;
            NSMutableSet<NSString *> *seen = [NSMutableSet set];
            for (NSString *u in item[@"urls"]) {
                if ([seen containsObject:u]) continue;
                [seen addObject:u];
                total++;
                NSURL *file = [ListenDownloads fileURLForRelativePath:[ListenDownloads relativePathForURL:[NSURL URLWithString:u]] root:_root];
                NSDictionary *attrs = [fm attributesOfItemAtPath:file.path error:nil];
                if (attrs) {
                    have++;
                    bytes += [attrs fileSize];
                }
            }
            items[item[@"itemId"]] = @{@"have": @(have), @"total": @(total), @"bytes": @(bytes)};
        }
        return @{@"root": _root.path ?: @"",
                 @"items": items,
                 @"pending": @(_pending.count + (_inflight ? 1 : 0))};
    }
}

@end
