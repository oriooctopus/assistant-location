#import "TodosViewController.h"

#import "BakedConfig.h"

// The host is the one build-time secret (GL_BAKED_HOST, from
// App/BakedConfig.h); this tab only owns its own port.
static NSInteger const kTodosPort = 8308;

@implementation TodosViewController

- (instancetype)init {
    NSString *urlString = [NSString stringWithFormat:@"http://%@:%ld/", GL_BAKED_HOST, (long)kTodosPort];
    return [self initWithURL:[NSURL URLWithString:urlString]
                  displayName:@"todo sorter"];
}

@end
