#import "FootballViewController.h"

#import "BakedConfig.h"

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

@end
