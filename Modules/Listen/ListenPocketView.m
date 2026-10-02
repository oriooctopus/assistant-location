#import "ListenPocketView.h"

#import "GLLog.h"
#import "GLTheme.h"
#import "ListenPlayer.h"

static NSTimeInterval const kPocketLongPressSeconds = 0.6;
static NSTimeInterval const kPocketExitLongPressSeconds = 1.0;
static CGFloat const kPocketZoneAlpha = 0.28;

@interface ListenPocketView () <UIGestureRecognizerDelegate>
@end

@implementation ListenPocketView {
    ListenPlayer *_player;
    UIButton *_exitButton;
    UILabel *_statusLabel;
    BOOL _presented;
    UIScreen *_screen;
    CGFloat _savedBrightness;
    BOOL _savedIdleTimerDisabled;
    BOOL _savedProximityEnabled;
}

- (instancetype)initWithPlayer:(ListenPlayer *)player {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _player = player;
        self.backgroundColor = [UIColor blackColor];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.accessibilityViewIsModal = YES;
        [self buildZones];
        [self buildExitButton];
        [self buildGestures];
    }
    return self;
}

#pragma mark - Layout

- (UILabel *)zoneLabelWithText:(NSString *)text {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont systemFontOfSize:34 weight:UIFontWeightBold];
    label.textColor = [[GLTheme textSecondaryColor] colorWithAlphaComponent:kPocketZoneAlpha];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.isAccessibilityElement = NO;
    return label;
}

- (void)buildZones {
    UILabel *hold = [self zoneLabelWithText:@"HOLD\nplay / pause"];
    UILabel *two = [self zoneLabelWithText:@"2 FINGERS\nagain"];
    UILabel *swipe = [self zoneLabelWithText:@"SWIPE\n← next    back →"];
    UILabel *three = [self zoneLabelWithText:@"3 FINGERS\nsave"];

    UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[hold, two]];
    UIStackView *bottom = [[UIStackView alloc] initWithArrangedSubviews:@[swipe, three]];
    for (UIStackView *row in @[top, bottom]) {
        row.axis = UILayoutConstraintAxisHorizontal;
        row.distribution = UIStackViewDistributionFillEqually;
    }
    UIStackView *grid = [[UIStackView alloc] initWithArrangedSubviews:@[top, bottom]];
    grid.axis = UILayoutConstraintAxisVertical;
    grid.distribution = UIStackViewDistributionFillEqually;
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    grid.userInteractionEnabled = NO;
    [self addSubview:grid];

    _statusLabel = [[UILabel alloc] init];
    _statusLabel.font = [GLTheme captionFont];
    _statusLabel.textColor = [[GLTheme textSecondaryColor] colorWithAlphaComponent:kPocketZoneAlpha];
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_statusLabel];

    UILayoutGuide *safe = self.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [grid.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [grid.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [grid.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [grid.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-([GLTheme controlHeight] + 2 * [GLTheme spacingL])],
        [_statusLabel.topAnchor constraintEqualToAnchor:safe.topAnchor constant:[GLTheme spacingXS]],
        [_statusLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
    ]];
}

- (void)buildExitButton {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:@"Exit pocket mode (hold 1 s)" forState:UIControlStateNormal];
    button.titleLabel.font = [GLTheme buttonFont];
    [button setTitleColor:[GLTheme textPrimaryColor] forState:UIControlStateNormal];
    button.backgroundColor = [GLTheme surfaceColor];
    button.layer.cornerRadius = [GLTheme cornerRadius];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:button];
    [NSLayoutConstraint activateConstraints:@[
        [button.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [button.bottomAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.bottomAnchor constant:-[GLTheme spacingL]],
        [button.heightAnchor constraintEqualToConstant:[GLTheme controlHeight]],
        [button.widthAnchor constraintGreaterThanOrEqualToConstant:260],
    ]];
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(exitHeld:)];
    hold.minimumPressDuration = kPocketExitLongPressSeconds;
    [button addGestureRecognizer:hold];
    _exitButton = button;
}

- (void)buildGestures {
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressed:)];
    longPress.minimumPressDuration = kPocketLongPressSeconds;
    longPress.numberOfTouchesRequired = 1;

    UITapGestureRecognizer *two = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(twoFingerTapped:)];
    two.numberOfTouchesRequired = 2;
    UITapGestureRecognizer *three = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(threeFingerTapped:)];
    three.numberOfTouchesRequired = 3;

    UISwipeGestureRecognizer *left = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swipedLeft:)];
    left.direction = UISwipeGestureRecognizerDirectionLeft;
    UISwipeGestureRecognizer *right = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swipedRight:)];
    right.direction = UISwipeGestureRecognizerDirectionRight;

    for (UIGestureRecognizer *gr in @[longPress, two, three, left, right]) {
        gr.delegate = self;
        [self addGestureRecognizer:gr];
    }
}

// The exit button has its own 1 s hold; the overlay-wide gestures must not
// also fire from a touch that starts on it.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldReceiveTouch:(UITouch *)touch {
    if (gr.view == _exitButton) return YES;
    return ![touch.view isDescendantOfView:_exitButton];
}

#pragma mark - Gestures

- (void)run:(NSString *)error {
    if (error && self.onError) self.onError(error);
}

- (void)longPressed:(UILongPressGestureRecognizer *)gr {
    if (gr.state == UIGestureRecognizerStateBegan) [self run:[_player toggle]];
}

- (void)twoFingerTapped:(UITapGestureRecognizer *)gr { [self run:[_player replay:@"original"]]; }
- (void)swipedLeft:(UISwipeGestureRecognizer *)gr { [self run:[_player next]]; }
- (void)swipedRight:(UISwipeGestureRecognizer *)gr { [self run:[_player prev]]; }

- (void)threeFingerTapped:(UITapGestureRecognizer *)gr {
    if (self.onSave) self.onSave();
}

- (void)exitHeld:(UILongPressGestureRecognizer *)gr {
    if (gr.state == UIGestureRecognizerStateBegan && self.onExitRequested) self.onExitRequested();
}

#pragma mark - Present / dismiss

- (NSString *)presentInWindow:(UIWindow *)window {
    if (_presented) return nil;
    UIScreen *screen = window.windowScene.screen;
    if (!screen) return @"pocket mode: window has no screen";
    _screen = screen;
    _savedBrightness = screen.brightness;
    _savedIdleTimerDisabled = [UIApplication sharedApplication].idleTimerDisabled;
    _savedProximityEnabled = [UIDevice currentDevice].proximityMonitoringEnabled;

    self.frame = window.bounds;
    [window addSubview:self];
    screen.brightness = 0;
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    [UIDevice currentDevice].proximityMonitoringEnabled = YES;
    _presented = YES;
    GLLog(@"pocket on: proximity supported=%d enabled=%d, brightness %.2f -> 0",
          [UIDevice currentDevice].proximityMonitoringEnabled, [UIDevice currentDevice].isProximityMonitoringEnabled, _savedBrightness);
    return nil;
}

- (void)dismiss {
    if (!_presented) return;
    _presented = NO;
    _screen.brightness = _savedBrightness;
    [UIApplication sharedApplication].idleTimerDisabled = _savedIdleTimerDisabled;
    [UIDevice currentDevice].proximityMonitoringEnabled = _savedProximityEnabled;
    [self removeFromSuperview];
    GLLog(@"pocket off: brightness restored to %.2f", _savedBrightness);
}

- (void)setStatusText:(NSString *)text {
    _statusLabel.text = text;
}

@end
