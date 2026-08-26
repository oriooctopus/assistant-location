#import "FinancesViewController.h"

#import "BakedConfig.h"

// The host is the one build-time secret (GL_BAKED_HOST, from
// App/BakedConfig.h); this tab only owns its own port and path.
static NSInteger const kFinancesPort = 8212;

@implementation FinancesViewController

- (instancetype)init {
    // Trailing slash is deliberate: lm-review's server proxies /app to a Vite dev
    // server when one is running, and that proxy once 404'd the bare /app (Vite's
    // base is /app/) while every other /app/* route kept working. Server-side is
    // fixed to redirect bare /app -> /app/, but requesting /app/ directly here is
    // defense in depth so a future proxy quirk can't strip this tab again.
    NSString *urlString = [NSString stringWithFormat:@"http://%@:%ld/app/", GL_BAKED_HOST, (long)kFinancesPort];
    return [self initWithURL:[NSURL URLWithString:urlString]
                  displayName:@"finances"];
}

@end
