#import "OutfitsViewController.h"

#import "BakedConfig.h"

// The host is the one build-time secret (GL_BAKED_HOST, from
// App/BakedConfig.h); this tab only owns its own port.
static NSInteger const kOutfitsPort = 8314;

static __weak OutfitsViewController *currentInstance;

@interface OutfitsViewController ()
// Verbatim, still-encoded text after "#/" ; nil = no deep link, load the base.
@property(nonatomic, copy) NSString *pendingPath;
@end

@implementation OutfitsViewController

+ (instancetype)current { return currentInstance; }

- (instancetype)init {
    // UITEST_OUTFITS_BASE_URL: CI has no baked host, so sim-test points the
    // tab at its local mock to give the web view a real page to navigate.
    NSString *urlString = [[NSProcessInfo processInfo] environment][@"UITEST_OUTFITS_BASE_URL"]
        ?: [NSString stringWithFormat:@"http://%@:%ld/", GL_BAKED_HOST, (long)kOutfitsPort];
    self = [self initWithURL:[NSURL URLWithString:urlString]
                 displayName:@"outfits"];
    if (self) currentInstance = self;
    return self;
}

- (NSURL *)webURL {
    NSURL *base = [super webURL];
    if (self.pendingPath == nil) return base;
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@#/%@", base.absoluteString, self.pendingPath]];
}

- (void)openPath:(NSString *)path {
    self.pendingPath = path;
    if (self.isViewLoaded) [self loadPage];
}

@end
