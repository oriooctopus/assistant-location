// Listen micro app: Spanish listening practice. A web app on port 8315 owns the
// data; native owns audio (AVQueuePlayer), Now Playing, pocket mode and voice
// commands. See PROTOCOL.md in this directory.

#import <Foundation/Foundation.h>
#import "GLModule.h"

@interface ListenModule : NSObject <GLModule>
@end
