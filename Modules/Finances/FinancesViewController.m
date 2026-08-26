#import "FinancesViewController.h"

#import "BakedConfig.h"

// The host is the one build-time secret (GL_BAKED_HOST, from
// App/BakedConfig.h); this tab only owns its own port and path.
static NSInteger const kFinancesPort = 8212;

@implementation FinancesViewController

- (instancetype)init {
    NSString *urlString = [NSString stringWithFormat:@"http://%@:%ld/app", GL_BAKED_HOST, (long)kFinancesPort];
    return [self initWithURL:[NSURL URLWithString:urlString]
                  displayName:@"finances"];
}

@end
