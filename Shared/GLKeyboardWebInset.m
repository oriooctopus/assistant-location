#import "GLKeyboardWebInset.h"

@interface GLKeyboardWebInset ()
@property(nonatomic, weak) UIView *container;
@property(nonatomic, strong) NSLayoutConstraint *bottomToSafeArea;
@property(nonatomic, strong) NSLayoutConstraint *bottomToContainerBottom;
@end

@implementation GLKeyboardWebInset

+ (instancetype)attachTo:(UIView *)hosted inContainer:(UIView *)container {
    GLKeyboardWebInset *inset = [[GLKeyboardWebInset alloc] init];
    inset.container = container;
    inset.bottomToSafeArea =
        [hosted.bottomAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.bottomAnchor];
    inset.bottomToContainerBottom =
        [hosted.bottomAnchor constraintEqualToAnchor:container.bottomAnchor];
    inset.bottomToSafeArea.active = YES;

    [[NSNotificationCenter defaultCenter] addObserver:inset
                                             selector:@selector(glKeyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:inset
                                             selector:@selector(glKeyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];
    return inset;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)extendsBelowSafeArea {
    return self.bottomToContainerBottom.isActive;
}

- (void)setExtendsBelowSafeArea:(BOOL)extends animationInfo:(NSDictionary *)animationInfo {
    // Already there. Re-activating would restart the animation for nothing, and
    // UIKeyboardWillShow fires more than once in ordinary use (a keyboard
    // changing height for an accessory view, a language switch).
    if (self.extendsBelowSafeArea == extends) return;

    self.bottomToSafeArea.active = !extends;
    self.bottomToContainerBottom.active = extends;

    UIView *container = self.container;
    NSNumber *duration = animationInfo[UIKeyboardAnimationDurationUserInfoKey];
    if (!duration) {
        // Driven directly, or a notification with no animation info: apply the
        // new layout at once rather than leaving it to the next runloop pass,
        // so a caller can measure the result immediately.
        [container layoutIfNeeded];
        return;
    }
    NSNumber *curve = animationInfo[UIKeyboardAnimationCurveUserInfoKey];
    // The curve arrives as a UIViewAnimationCurve, which occupies the high bits
    // of UIViewAnimationOptions -- hence the shift, not a cast.
    UIViewAnimationOptions options = (UIViewAnimationOptions)(curve.integerValue << 16);
    [UIView animateWithDuration:duration.doubleValue
                          delay:0
                        options:options
                     animations:^{ [container layoutIfNeeded]; }
                     completion:nil];
}

- (void)glKeyboardWillShow:(NSNotification *)note {
    [self setExtendsBelowSafeArea:YES animationInfo:note.userInfo];
}

- (void)glKeyboardWillHide:(NSNotification *)note {
    [self setExtendsBelowSafeArea:NO animationInfo:note.userInfo];
}

@end
