#import "OutfitsViewController.h"

#import "BakedConfig.h"

// The host is the one build-time secret (GL_BAKED_HOST, from
// App/BakedConfig.h); this tab only owns its own port.
static NSInteger const kOutfitsPort = 8314;

@implementation OutfitsViewController

- (instancetype)init {
    NSString *urlString = [NSString stringWithFormat:@"http://%@:%ld/", GL_BAKED_HOST, (long)kOutfitsPort];
    return [self initWithURL:[NSURL URLWithString:urlString]
                 displayName:@"outfits"];
}

@end
