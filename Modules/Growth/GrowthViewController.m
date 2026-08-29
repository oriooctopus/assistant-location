#import "GrowthViewController.h"

#import "BakedConfig.h"

// The host is the one build-time secret (GL_BAKED_HOST, from
// App/BakedConfig.h); this tab only owns its own port.
static NSInteger const kGrowthPort = 8312;

@implementation GrowthViewController

- (instancetype)init {
    NSString *urlString = [NSString stringWithFormat:@"http://%@:%ld/", GL_BAKED_HOST, (long)kGrowthPort];
    return [self initWithURL:[NSURL URLWithString:urlString]
                  displayName:@"growth"];
}

@end
