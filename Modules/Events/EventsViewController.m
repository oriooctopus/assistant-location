#import "EventsViewController.h"

#import "BakedConfig.h"

// The host is the one build-time secret (GL_BAKED_HOST, from
// App/BakedConfig.h); this tab only owns its own port.
static NSInteger const kEventsPort = 8304;

@implementation EventsViewController

- (instancetype)init {
    NSString *urlString = [NSString stringWithFormat:@"http://%@:%ld/", GL_BAKED_HOST, (long)kEventsPort];
    return [self initWithURL:[NSURL URLWithString:urlString]
                  displayName:@"event finder"];
}

@end
