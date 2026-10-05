// Tiny in-process HTTP/1.1 server on 127.0.0.1 for the offline-shell tests.
// POSIX sockets + a dispatch read source, no dependencies. Every response
// carries Connection: close, so stopping the server leaves nothing keeping a
// kept-alive socket open (a stopped server must refuse connections).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GLTestHTTPResponse : NSObject
@property(nonatomic) NSInteger status;
@property(nonatomic, copy) NSString *contentType;
@property(nonatomic, copy) NSData *body;
+ (instancetype)html:(NSString *)html;
+ (instancetype)status:(NSInteger)status contentType:(NSString *)contentType body:(NSString *)body;
@end

@interface GLTestHTTPServer : NSObject
/// Returns a response, or nil to accept the request and never answer it (the
/// connection is held open until -stop), which is how a "no response within
/// the deadline" server is simulated. Called on a background queue.
@property(nonatomic, copy) GLTestHTTPResponse *_Nullable (^handler)(NSString *method, NSString *path);
@property(nonatomic, readonly) uint16_t port;
/// Paths (with query) received so far, in order.
@property(nonatomic, readonly) NSArray<NSString *> *requestedPaths;

/// port 0 picks a free one; pass a previous server's port to bring it back.
- (BOOL)startOnPort:(uint16_t)port error:(NSError **)error;
/// Synchronous: once this returns the port refuses connections.
- (void)stop;
- (NSURL *)URLForPath:(NSString *)path;
@end

NS_ASSUME_NONNULL_END
