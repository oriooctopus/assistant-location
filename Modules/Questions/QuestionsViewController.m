#import "QuestionsViewController.h"

#import <WebKit/WebKit.h>

#import "GLModuleRegistry.h"

NSString *const kQuestionsOpenNotification = @"GLQuestionsOpen";

@interface GLWebModuleViewController (QuestionsNavigationDelegate)
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation;
@end

// Class-level state: the tap can arrive before the page has loaded (cold
// launch), so the ref waits here until the page confirms it ran openQuestion.
static NSDictionary *sPendingRef;
static __weak QuestionsViewController *sInstance;

@implementation QuestionsViewController

- (instancetype)initWithURL:(NSURL *)url displayName:(NSString *)displayName {
    self = [super initWithURL:url displayName:displayName];
    if (self) sInstance = self;
    return self;
}

+ (void)handleOpenRequest:(NSDictionary *)ref {
    sPendingRef = ref;
    [self openTileAttempt:0];
    [sInstance deliverPendingRef];
}

// On a cold launch the More coordinator may not exist yet, in which case
// showModuleWithIdentifier: returns NO; retry briefly.
+ (void)openTileAttempt:(int)attempt {
    if ([GLModuleRegistry showModuleWithIdentifier:@"GLModule.QuestionsModule"]) return;
    if (attempt >= 20) {
        NSLog(@"[Questions] could not open the Questions tile after %d attempts", attempt);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self openTileAttempt:attempt + 1]; });
}

- (void)deliverPendingRef {
    NSDictionary *ref = sPendingRef;
    if (!ref) return;
    [self callWebFunctionIfDefined:@"openQuestion" withJSONArgument:ref completion:^(BOOL ran) {
        if (ran && sPendingRef == ref) sPendingRef = nil;
    }];
}

// Refresh the list whenever the screen comes back (a new push may have
// arrived while it was in the background).
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self callWebFunctionIfDefined:@"refreshQuestions"];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [super webView:webView didFinishNavigation:navigation];
    [self deliverPendingRef];
}

@end
