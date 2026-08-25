#import "FootballViewController.h"

#import "BakedConfig.h"
#import "FootballNotificationScheduler.h"

// The host is the one build-time secret (GL_BAKED_HOST, from
// App/BakedConfig.h); this tab only owns its own port. Same port as Events —
// it's the same server, just pinned to the football view via ?tab=football.
static NSInteger const kFootballPort = 8304;

@implementation FootballViewController

- (instancetype)init {
    NSString *urlString = [NSString stringWithFormat:@"http://%@:%ld/?tab=football", GL_BAKED_HOST, (long)kFootballPort];
    return [self initWithURL:[NSURL URLWithString:urlString]
                  displayName:@"football"];
}

// One of the three kickoff-reminder reconcile call sites (see
// FootballNotificationScheduler.h) -- fires every time this tab is shown,
// which is also the point a fresh swipe (mark_fixture) is most likely to
// have just happened.
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [FootballNotificationScheduler reconcile];
}

@end
