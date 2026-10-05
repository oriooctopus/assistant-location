#import "GLTestHTTPServer.h"

#import <arpa/inet.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

@implementation GLTestHTTPResponse
+ (instancetype)html:(NSString *)html {
    return [self status:200 contentType:@"text/html; charset=utf-8" body:html];
}
+ (instancetype)status:(NSInteger)status contentType:(NSString *)contentType body:(NSString *)body {
    GLTestHTTPResponse *r = [[GLTestHTTPResponse alloc] init];
    r.status = status;
    r.contentType = contentType;
    r.body = [body dataUsingEncoding:NSUTF8StringEncoding];
    return r;
}
@end

@implementation GLTestHTTPServer {
    int _listenFD;
    dispatch_source_t _acceptSource;
    dispatch_queue_t _queue;
    NSMutableArray<NSString *> *_paths;
    NSMutableArray<NSNumber *> *_heldFDs;  // connections we deliberately never answer
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _listenFD = -1;
        _queue = dispatch_queue_create("GLTestHTTPServer", DISPATCH_QUEUE_CONCURRENT);
        _paths = [NSMutableArray array];
        _heldFDs = [NSMutableArray array];
    }
    return self;
}

- (NSArray<NSString *> *)requestedPaths {
    @synchronized(self) { return [_paths copy]; }
}

- (NSURL *)URLForPath:(NSString *)path {
    return [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u%@", _port, path]];
}

- (BOOL)startOnPort:(uint16_t)port error:(NSError **)error {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    struct sockaddr_in addr = {0};
    addr.sin_len = sizeof addr;
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) != 0 || listen(fd, 16) != 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                           [NSString stringWithFormat:@"bind/listen 127.0.0.1:%u failed", port]}];
        close(fd);
        return NO;
    }
    socklen_t len = sizeof addr;
    getsockname(fd, (struct sockaddr *)&addr, &len);
    _port = ntohs(addr.sin_port);
    _listenFD = fd;
    fcntl(fd, F_SETFL, O_NONBLOCK);

    _acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, _queue);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_acceptSource, ^{
        for (;;) {
            int client = accept(fd, NULL, NULL);
            if (client < 0) return;
            int nosigpipe = 1;
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof nosigpipe);
            GLTestHTTPServer *strongSelf = weakSelf;
            if (!strongSelf) { close(client); return; }
            dispatch_async(strongSelf->_queue, ^{ [strongSelf serveClient:client]; });
        }
    });
    dispatch_source_set_cancel_handler(_acceptSource, ^{ close(fd); });
    dispatch_resume(_acceptSource);
    return YES;
}

- (void)serveClient:(int)client {
    // Blocking reads on a per-connection queue block; the accept fd above stays non-blocking.
    int flags = fcntl(client, F_GETFL);
    fcntl(client, F_SETFL, flags & ~O_NONBLOCK);
    NSMutableData *request = [NSMutableData data];
    char buf[4096];
    while ([request rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]
                        options:0 range:NSMakeRange(0, request.length)].location == NSNotFound) {
        ssize_t n = read(client, buf, sizeof buf);
        if (n <= 0) { close(client); return; }
        [request appendBytes:buf length:(NSUInteger)n];
        if (request.length > 65536) { close(client); return; }
    }
    NSString *head = [[NSString alloc] initWithData:request encoding:NSUTF8StringEncoding];
    NSArray<NSString *> *first = [[head componentsSeparatedByString:@"\r\n"].firstObject componentsSeparatedByString:@" "];
    if (first.count < 2) { close(client); return; }
    NSString *method = first[0], *path = first[1];
    @synchronized(self) { [_paths addObject:path]; }

    GLTestHTTPResponse *response = self.handler ? self.handler(method, path) : nil;
    if (!response) {
        @synchronized(self) { [_heldFDs addObject:@(client)]; }
        return;
    }
    NSString *reason = response.status == 200 ? @"OK" : (response.status == 404 ? @"Not Found" : @"Status");
    NSString *header = [NSString stringWithFormat:
        @"HTTP/1.1 %ld %@\r\nContent-Type: %@\r\nContent-Length: %lu\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
        (long)response.status, reason, response.contentType, (unsigned long)response.body.length];
    NSMutableData *out = [[header dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [out appendData:response.body];
    const char *p = out.bytes;
    size_t left = out.length;
    while (left > 0) {
        ssize_t n = write(client, p, left);
        if (n <= 0) break;
        p += n;
        left -= (size_t)n;
    }
    close(client);
}

- (void)stop {
    if (_acceptSource) {
        dispatch_semaphore_t closed = dispatch_semaphore_create(0);
        dispatch_source_set_cancel_handler(_acceptSource, ^{
            close(self->_listenFD);
            dispatch_semaphore_signal(closed);
        });
        dispatch_source_cancel(_acceptSource);
        dispatch_semaphore_wait(closed, DISPATCH_TIME_FOREVER);
        _acceptSource = nil;
        _listenFD = -1;
    }
    @synchronized(self) {
        for (NSNumber *fd in _heldFDs) close(fd.intValue);
        [_heldFDs removeAllObjects];
    }
}

@end
