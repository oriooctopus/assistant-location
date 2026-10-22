#import "DebateViewController.h"

#import "BakedConfig.h"

// The host is the one build-time secret (GL_BAKED_HOST, from
// App/BakedConfig.h); this tab only owns its own port. HTTPS on 9335
// (`tailscale serve`, tailnet-only) so the app's own service worker, which is
// secure-context gated, can register -- same reasoning as Todos on 9308.
static NSInteger const kDebatePort = 9335;

@implementation DebateViewController

- (instancetype)init {
    NSString *urlString = [NSString stringWithFormat:@"https://%@:%ld/", GL_BAKED_HOST, (long)kDebatePort];
    return [self initWithURL:[NSURL URLWithString:urlString]
                 displayName:@"debate"];
}

@end
