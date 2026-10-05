#import "GoalTrackerViewController.h"

#import "BakedConfig.h"

// The host is the one build-time secret (GL_BAKED_HOST, from
// App/BakedConfig.h); this tab only owns its own port.
static NSInteger const kGoalTrackerPort = 8316;

@implementation GoalTrackerViewController

- (instancetype)init {
    NSString *urlString = [NSString stringWithFormat:@"http://%@:%ld/", GL_BAKED_HOST, (long)kGoalTrackerPort];
    return [self initWithURL:[NSURL URLWithString:urlString]
                 displayName:@"goal-tracker"];
}

@end
