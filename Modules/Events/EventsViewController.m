#import "EventsViewController.h"

// Same tailnet-IP style as GL_BAKED_BASE_URL in BakedConfig.h (rather than
// the wsl-esme-1.tailc6cd5d.ts.net hostname), for consistency with the rest
// of the app's baked config.
static NSString *const kEventsURLString = @"http://100.103.237.24:8304/";

@implementation EventsViewController

- (instancetype)init {
    return [self initWithURL:[NSURL URLWithString:kEventsURLString]
                  displayName:@"event finder"];
}

@end
