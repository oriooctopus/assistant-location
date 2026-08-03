#import "GLComponents.h"

#import "GLTheme.h"

static NSTimeInterval const kGLToastDuration = 2.0;
static NSTimeInterval const kGLToastFadeDuration = 0.25;

@implementation GLComponents

+ (UIButton *)primaryButtonWithTitle:(NSString *)title {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [GLTheme buttonFont];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.backgroundColor = [GLTheme accentColor];
    button.layer.cornerRadius = [GLTheme cornerRadius];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.heightAnchor constraintEqualToConstant:[GLTheme controlHeight]].active = YES;
    return button;
}

+ (UILabel *)statusLabel {
    UILabel *label = [[UILabel alloc] init];
    label.font = [GLTheme captionFont];
    label.textColor = [GLTheme textSecondaryColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

+ (UIView *)emptyStateViewWithMessage:(NSString *)message {
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *label = [self statusLabel];
    label.font = [GLTheme bodyFont];
    label.text = message;
    [container addSubview:label];

    UILayoutGuide *guide = container.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [label.leadingAnchor constraintGreaterThanOrEqualToAnchor:guide.leadingAnchor
                                                          constant:[GLTheme spacingL]],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:guide.trailingAnchor
                                                         constant:-[GLTheme spacingL]],
    ]];
    return container;
}

+ (UIView *)failureViewWithMessage:(NSString *)message
                       retryHandler:(void (^)(void))retryHandler {
    UIView *container = [[UIView alloc] init];
    container.backgroundColor = [GLTheme backgroundColor];
    container.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *label = [self statusLabel];
    label.font = [GLTheme bodyFont];
    label.textColor = [GLTheme textPrimaryColor];
    label.text = message;

    UIButton *retryButton = [self primaryButtonWithTitle:@"Retry"];
    [retryButton addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
        retryHandler();
    }] forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ label, retryButton ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = [GLTheme spacingL];
    stack.alignment = UIStackViewAlignmentCenter;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:stack];

    UILayoutGuide *guide = container.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:guide.leadingAnchor
                                                          constant:[GLTheme spacingL]],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:guide.trailingAnchor
                                                         constant:-[GLTheme spacingL]],
    ]];
    return container;
}

+ (void)showToastInView:(UIView *)view message:(NSString *)message {
    UILabel *label = [[UILabel alloc] init];
    label.text = message;
    label.font = [GLTheme captionFont];
    label.textColor = UIColor.whiteColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.backgroundColor = [[GLTheme textPrimaryColor] colorWithAlphaComponent:0.85];
    label.layer.cornerRadius = [GLTheme cornerRadius];
    label.layer.masksToBounds = YES;
    label.alpha = 0;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:label];

    UILayoutGuide *guide = view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:guide.centerXAnchor],
        [label.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor
                                            constant:-[GLTheme spacingL]],
        [label.leadingAnchor constraintGreaterThanOrEqualToAnchor:guide.leadingAnchor
                                                          constant:[GLTheme spacingL]],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:guide.trailingAnchor
                                                         constant:-[GLTheme spacingL]],
    ]];
    // UILabel has no built-in content insets — give the background a bit of
    // breathing room around the text via layoutMargins-driven padding isn't
    // available on UILabel either, so grow the frame via an explicit inset
    // wrapper would be more code than this toast needs; the corner radius +
    // font already read fine flush against the text edges for a one-line
    // confirmation.

    [UIView animateWithDuration:kGLToastFadeDuration
                     animations:^{ label.alpha = 1; }
                     completion:^(BOOL finished) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kGLToastDuration * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:kGLToastFadeDuration
                             animations:^{ label.alpha = 0; }
                             completion:^(BOOL finished2) {
                [label removeFromSuperview];
            }];
        });
    }];
}

@end
