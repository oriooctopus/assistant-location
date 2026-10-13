#import "SleepTrackerViewController.h"

#import "BakedConfig.h"

// The host is the one build-time secret (GL_BAKED_HOST, from
// App/BakedConfig.h); this tab only owns its own port.
static NSInteger const kSleepTrackerPort = 8325;

@implementation SleepTrackerViewController

- (instancetype)init {
    NSString *urlString = [NSString stringWithFormat:@"http://%@:%ld/", GL_BAKED_HOST, (long)kSleepTrackerPort];
    return [self initWithURL:[NSURL URLWithString:urlString]
                 displayName:@"sleep-tracker"];
}

@end
