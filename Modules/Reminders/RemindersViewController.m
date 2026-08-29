#import "RemindersViewController.h"

#import "BakedConfig.h"

// The host is the one build-time secret (GL_BAKED_HOST, from
// App/BakedConfig.h); this tab only owns its own port.
static NSInteger const kRemindersPort = 8312;

@implementation RemindersViewController

- (instancetype)init {
    NSString *urlString = [NSString stringWithFormat:@"http://%@:%ld/", GL_BAKED_HOST, (long)kRemindersPort];
    return [self initWithURL:[NSURL URLWithString:urlString]
                  displayName:@"reminders"];
}

@end
