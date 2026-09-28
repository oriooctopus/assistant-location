#import "QuestionsModule.h"

#import "GLModuleRegistry.h"
#import "QuestionsViewController.h"

@implementation QuestionsModule

+ (void)load {
    [GLModuleRegistry registerModule:self];
}

+ (NSString *)moduleTitle { return @"Facebook"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"questionmark.bubble"]; }

// 680: right after Quotes (670) -- keep in sync with MODULES.md and
// more.html's DEFAULT_ORDER (events/test_more_grid_order.py enforces it).
+ (NSInteger)moduleOrder { return 680; }

// More-overflow module: returned unwrapped, same as SessionsModule.
+ (UIViewController *)makeViewController {
    return [[QuestionsViewController alloc] initWithManagedPageNamed:@"questions.html"];
}

// Runs at launch for every module, before any tap can be delivered, so a
// Marketplace push tapped from a cold start still has an observer.
+ (void)moduleDidFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [[NSNotificationCenter defaultCenter] addObserverForName:kQuestionsOpenNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        [QuestionsViewController handleOpenRequest:note.userInfo];
    }];
}

@end
