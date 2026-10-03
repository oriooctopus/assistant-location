#import "GLWebBackSwipe.h"

@implementation GLWebBackSwipe

+ (void)applyPageCanGoBack:(BOOL)pageCanGoBack
    toNavigationController:(UINavigationController *)navigationController {
    if (navigationController == nil) return;
    BOOL navOwnsSwipe = !pageCanGoBack;
    navigationController.interactivePopGestureRecognizer.enabled = navOwnsSwipe;
    [self contentPopGestureRecognizerOf:navigationController].enabled = navOwnsSwipe;
}

+ (UIGestureRecognizer *)contentPopGestureRecognizerOf:(UINavigationController *)navigationController {
    SEL selector = NSSelectorFromString(@"interactiveContentPopGestureRecognizer");
    if (![navigationController respondsToSelector:selector]) return nil;
    return [navigationController valueForKey:NSStringFromSelector(selector)];
}

@end
