#import "GLDurableOutboxShared.h"

#import <UIKit/UIKit.h>

#import "BakedConfig.h"
#import "GLEndpoints.h"

@implementation GLDurableOutbox (Shared)

+ (GLDurableOutbox *)shared {
    static GLDurableOutbox *outbox;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSError *error = nil;
        NSURL *support = [[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory
                                                                inDomain:NSUserDomainMask
                                                       appropriateForURL:nil
                                                                  create:YES
                                                                   error:&error];
        if (!support) [NSException raise:NSInternalInconsistencyException format:@"no Application Support: %@", error];
        outbox = [[GLDurableOutbox alloc] initWithDirectory:[support URLByAppendingPathComponent:@"DurableOutbox" isDirectory:YES]
                                                 urlBuilder:^NSURL *(NSString *path) { return GLEndpointURL(path); }
                                                      token:GL_BAKED_TOKEN
                                       sessionConfiguration:nil];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:^(NSNotification *note) { [outbox flushWithCompletion:nil]; }];
        [outbox flushWithCompletion:nil];
    });
    return outbox;
}

@end
