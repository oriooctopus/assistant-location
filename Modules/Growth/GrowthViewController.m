#import "GrowthViewController.h"

#import "BakedConfig.h"
#import "GLWebBridge.h"

// The host is the one build-time secret (GL_BAKED_HOST, from
// App/BakedConfig.h); this tab only owns its own port.
static NSInteger const kGrowthPort = 8312;

// -loadPage is private to GLWebModuleViewController; redeclared here so a
// demo-mode flip can reload the page with the new URL.
@interface GLWebModuleViewController (GrowthReload)
- (void)loadPage;
@end

@interface GrowthViewController ()
/// Demo mode: the page is loaded with ?demo=1, which makes the Growth web
/// app show a fixed set of harmless items and never write to AnyList. Set by
/// holding the Growth tile on the More page (more.html sends demo:true on
/// openModule); an ordinary tap sends demo:false and turns it back off.
@property (nonatomic, assign) BOOL demoMode;
@end

@implementation GrowthViewController

- (instancetype)init {
    NSString *urlString = [NSString stringWithFormat:@"http://%@:%ld/", GL_BAKED_HOST, (long)kGrowthPort];
    self = [self initWithURL:[NSURL URLWithString:urlString]
                  displayName:@"growth"];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(moduleWillOpen:)
                                                     name:GLWebBridgeWillOpenModuleNotification
                                                   object:nil];
    }
    return self;
}

// Posted synchronously before the push, so on a first open (view not yet
// loaded) viewDidLoad's own -loadPage already picks up the new URL; only an
// already-loaded page whose mode actually changed needs a reload.
- (void)moduleWillOpen:(NSNotification *)note {
    if (![note.userInfo[@"identifier"] isEqual:self.restorationIdentifier]) return;
    BOOL demo = [note.userInfo[@"demo"] boolValue];
    if (demo == self.demoMode) return;
    self.demoMode = demo;
    if (self.isViewLoaded) [self loadPage];
}

- (NSURL *)webURL {
    NSURL *url = [super webURL];
    if (!self.demoMode) return url;
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSMutableArray<NSURLQueryItem *> *items = [components.queryItems mutableCopy] ?: [NSMutableArray array];
    [items addObject:[NSURLQueryItem queryItemWithName:@"demo" value:@"1"]];
    components.queryItems = items;
    return components.URL;
}

@end
