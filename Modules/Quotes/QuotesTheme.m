#import "QuotesTheme.h"

const NSInteger QuotesGridColumns = 6;
const NSInteger QuotesGridRows = 8;

#pragma mark - Circle path

// The loop the decorative circle walks, one step per calendar day: a 4x2 ring
// through cols 3...6 of rows 2 and 3. Consecutive entries (and last -> first)
// are edge-adjacent cells, so the circle moves exactly one cell a day.
static const QuotesGridCell kCircleLoop[] = {
    {3, 2}, {4, 2}, {5, 2}, {6, 2}, {6, 3}, {5, 3}, {4, 3}, {3, 3},
};
static const NSInteger kCircleLoopLength = (NSInteger)(sizeof(kCircleLoop) / sizeof(kCircleLoop[0]));

BOOL QuotesTodayCellIsReserved(QuotesGridCell cell) {
    if (cell.row == 1) return YES;                    // day number + nav links
    if (cell.row == 2 && cell.col <= 2) return YES;   // date line under the number
    if (cell.row >= 4) return YES;                    // quote block, author, footer
    return NO;
}

QuotesGridCell QuotesDecorativeCircleCell(NSDate *date, NSCalendar *calendar) {
    // Count days from the local calendar date with plain integer arithmetic
    // (Hinnant's days_from_civil). ordinalityOfUnit:Day inUnit:Era is not
    // constant across one local day around DST changes.
    NSDateComponents *c = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:date];
    NSInteger y = c.year - (c.month <= 2);
    NSInteger era = y / 400;
    NSInteger yoe = y - era * 400;
    NSInteger doy = (153 * (c.month + (c.month > 2 ? -3 : 9)) + 2) / 5 + c.day - 1;
    NSInteger doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    NSInteger dayNumber = era * 146097 + doe - 719468;
    return kCircleLoop[dayNumber % kCircleLoopLength];
}

#pragma mark - Paging

BOOL QuotesPageCanMove(NSInteger index, NSInteger delta, NSInteger count) {
    NSInteger target = index + delta;
    return target >= 0 && target < count;
}

NSInteger QuotesPageIndexAfter(NSInteger index, NSInteger delta, NSInteger count) {
    return (index + delta + count) % count; // TEMP BREAK: wraps
}

BOOL QuotesPageShowsTodayLink(NSInteger viewing, NSInteger today) {
    return viewing != today;
}

NSInteger QuotesPageIndexForTodayTap(NSInteger viewing, NSInteger today) {
    return today;
}

NSString *QuotesPageMetaText(NSInteger index, NSInteger count) {
    return [NSString stringWithFormat:@"%04ld / %ld", (long)index + 1, (long)count];
}

#pragma mark - Theme

static UIColor *QuotesDynamic(UInt32 light, UInt32 dark) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        UInt32 hex = traits.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
        return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0
                               green:((hex >> 8) & 0xFF) / 255.0
                                blue:(hex & 0xFF) / 255.0
                               alpha:1];
    }];
}

@interface UIViewController (QuotesBack)
- (void)quotes_popSelf;
@end

@implementation UIViewController (QuotesBack)
- (void)quotes_popSelf {
    [self.navigationController popViewControllerAnimated:YES];
}
@end

@implementation QuotesTheme

+ (UIColor *)paper { return QuotesDynamic(0xF2F0EB, 0x0E0E0E); }
+ (UIColor *)ink { return QuotesDynamic(0x0C0C0C, 0xF0EEE8); }
+ (UIColor *)red { return QuotesDynamic(0xE4002B, 0xE4002B); }
+ (UIColor *)hairline { return QuotesDynamic(0xCFCBC0, 0x2A2926); }
+ (UIColor *)grey { return QuotesDynamic(0x8F8B80, 0x8F8B80); }
+ (UIColor *)dayGrey { return QuotesDynamic(0xB8B4A8, 0x3A3833); }

+ (UIColor *)backgroundColor { return [self paper]; }
+ (UIColor *)surfaceColor { return [self paper]; }
+ (UIColor *)accentColor { return [self red]; }
+ (UIColor *)destructiveColor { return [self ink]; }
+ (UIColor *)textPrimaryColor { return [self ink]; }
+ (UIColor *)textSecondaryColor { return [self grey]; }

+ (UIFont *)fontOfSize:(CGFloat)size {
    UIFont *font = [UIFont fontWithName:@"HelveticaNeue" size:size];
    NSAssert(font != nil, @"HelveticaNeue missing from the system font set");
    return font;
}
+ (UIFont *)titleFont { return [self fontOfSize:18]; }
+ (UIFont *)bodyFont { return [self fontOfSize:16]; }
+ (UIFont *)buttonFont { return [self fontOfSize:13]; }
+ (UIFont *)captionFont { return [self fontOfSize:11]; }

+ (CGFloat)spacingXXS { return 4; }
+ (CGFloat)spacingXS { return 8; }
+ (CGFloat)spacingS { return 12; }
+ (CGFloat)spacingM { return 16; }
+ (CGFloat)spacingL { return 24; }
+ (CGFloat)cornerRadius { return 0; }
+ (CGFloat)controlHeight { return 44; }

+ (void)styleScreenView:(UIView *)view {
    view.backgroundColor = [self paper];
    view.tintColor = [self ink];
}

+ (void)styleField:(UIView *)field {
    field.backgroundColor = [self paper];
    field.layer.cornerRadius = 0;
    field.layer.borderWidth = 0.5;
    field.layer.borderColor = [[self hairline] resolvedColorWithTraitCollection:field.traitCollection].CGColor;
}

+ (UIButton *)textLinkWithTitle:(NSString *)title {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[self ink] forState:UIControlStateNormal];
    [button setTitleColor:[self grey] forState:UIControlStateHighlighted];
    button.titleLabel.font = [self fontOfSize:11];
    button.contentEdgeInsets = UIEdgeInsetsMake(14, 9, 14, 9); // 11pt text + 28 = 44pt tall tap area
    return button;
}

+ (UIButton *)primaryButtonWithTitle:(NSString *)title {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [self buttonFont];
    [button setTitleColor:[self paper] forState:UIControlStateNormal];
    [button setTitleColor:[self grey] forState:UIControlStateDisabled];
    button.backgroundColor = [self ink];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.heightAnchor constraintEqualToConstant:[self controlHeight]].active = YES;
    return button;
}

+ (UILabel *)statusLabel {
    UILabel *label = [[UILabel alloc] init];
    label.font = [self captionFont];
    label.textColor = [self grey];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

+ (UIView *)emptyStateViewWithMessage:(NSString *)message {
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *label = [self statusLabel];
    label.font = [self bodyFont];
    label.text = message;
    [container addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [label.leadingAnchor constraintGreaterThanOrEqualToAnchor:container.layoutMarginsGuide.leadingAnchor constant:[self spacingL]],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:container.layoutMarginsGuide.trailingAnchor constant:-[self spacingL]],
    ]];
    return container;
}

+ (void)showToastInView:(UIView *)view message:(NSString *)message {
    UILabel *label = [[UILabel alloc] init];
    label.text = message;
    label.font = [self captionFont];
    label.textColor = [self paper];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.backgroundColor = [self ink];
    label.alpha = 0;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:label];
    UILayoutGuide *guide = view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:guide.centerXAnchor],
        [label.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-[self spacingL]],
        [label.leadingAnchor constraintGreaterThanOrEqualToAnchor:guide.leadingAnchor constant:[self spacingL]],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:guide.trailingAnchor constant:-[self spacingL]],
    ]];
    [UIView animateWithDuration:0.2 animations:^{ label.alpha = 1; } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.3 delay:2.0 options:0 animations:^{ label.alpha = 0; } completion:^(BOOL done) {
            [label removeFromSuperview];
        }];
    }];
}

+ (void)installBackLinkInViewController:(UIViewController *)viewController {
    static const CGFloat kStrip = 44;
    UIEdgeInsets extra = viewController.additionalSafeAreaInsets;
    extra.top += kStrip;
    viewController.additionalSafeAreaInsets = extra;

    UIView *view = viewController.view;
    UIButton *back = [self textLinkWithTitle:@"Back"];
    back.titleLabel.font = [self buttonFont];
    back.translatesAutoresizingMaskIntoConstraints = NO;
    back.accessibilityLabel = @"Back";
    [back addTarget:viewController action:@selector(quotes_popSelf) forControlEvents:UIControlEventTouchUpInside];
    [view addSubview:back];

    UIView *rule = [[UIView alloc] init];
    rule.backgroundColor = [self hairline];
    rule.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:rule];

    UILayoutGuide *guide = view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [back.topAnchor constraintEqualToAnchor:guide.topAnchor constant:-kStrip],
        [back.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:[self spacingXS]],
        [back.heightAnchor constraintEqualToConstant:kStrip],
        [rule.topAnchor constraintEqualToAnchor:guide.topAnchor constant:-0.5],
        [rule.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [rule.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [rule.heightAnchor constraintEqualToConstant:0.5],
    ]];
}

@end

#pragma mark - QuotesGridView

@implementation QuotesGridView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _columns = QuotesGridColumns;
        _rows = QuotesGridRows;
        self.backgroundColor = [QuotesTheme paper];
        self.contentMode = UIViewContentModeRedraw;
        self.isAccessibilityElement = NO;
    }
    return self;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [[QuotesTheme hairline] setStroke];
    CGContextSetLineWidth(ctx, 0.5);
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    for (NSInteger c = 0; c <= self.columns; c++) {
        CGFloat x = MIN(MAX(w * (CGFloat)c / (CGFloat)self.columns, 0.25), w - 0.25);
        CGContextMoveToPoint(ctx, x, 0);
        CGContextAddLineToPoint(ctx, x, h);
    }
    for (NSInteger r = 0; r <= self.rows; r++) {
        CGFloat y = MIN(MAX(h * (CGFloat)r / (CGFloat)self.rows, 0.25), h - 0.25);
        CGContextMoveToPoint(ctx, 0, y);
        CGContextAddLineToPoint(ctx, w, y);
    }
    CGContextStrokePath(ctx);
}

@end

#pragma mark - QuotesToggle

@interface QuotesToggle ()
@property(nonatomic, copy) NSArray<NSString *> *items;
@end

@implementation QuotesToggle

- (instancetype)initWithItems:(NSArray<NSString *> *)items {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _items = [items copy];
        self.backgroundColor = [QuotesTheme paper];
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}

- (void)setSelectedSegmentIndex:(NSInteger)index {
    _selectedSegmentIndex = index;
    [self setNeedsDisplay];
}

- (CGSize)intrinsicContentSize {
    CGFloat per = self.cellWidth > 0 ? self.cellWidth : 97;
    return CGSizeMake(per * (CGFloat)self.items.count, 36);
}

- (CGFloat)cellWidthForBounds {
    return self.cellWidth > 0 ? self.cellWidth : self.bounds.size.width / (CGFloat)self.items.count;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    CGFloat cw = [self cellWidthForBounds];
    NSMutableParagraphStyle *para = [[NSMutableParagraphStyle alloc] init];
    para.alignment = NSTextAlignmentCenter;
    for (NSUInteger i = 0; i < self.items.count; i++) {
        BOOL on = (NSInteger)i == self.selectedSegmentIndex;
        CGRect cell = CGRectMake(cw * (CGFloat)i, 0, cw, self.bounds.size.height);
        if (on) {
            [[QuotesTheme ink] setFill];
            UIRectFill(cell);
        } else {
            [[QuotesTheme hairline] setStroke];
            UIBezierPath *box = [UIBezierPath bezierPathWithRect:CGRectInset(cell, 0.25, 0.25)];
            box.lineWidth = 0.5;
            [box stroke];
        }
        UIFont *font = [QuotesTheme buttonFont];
        CGRect text = CGRectMake(cell.origin.x, (cell.size.height - font.lineHeight) / 2, cell.size.width, font.lineHeight);
        [self.items[i] drawInRect:text withAttributes:@{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: on ? [QuotesTheme paper] : [QuotesTheme grey],
            NSParagraphStyleAttributeName: para,
        }];
    }
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event { return YES; }

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    CGPoint p = [touch locationInView:self];
    if (!CGRectContainsPoint(self.bounds, p)) return;
    NSInteger index = (NSInteger)(p.x / [self cellWidthForBounds]);
    if (index < 0 || index >= (NSInteger)self.items.count || index == self.selectedSegmentIndex) return;
    self.selectedSegmentIndex = index;
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

- (BOOL)isAccessibilityElement { return NO; }

- (NSArray *)accessibilityElements {
    NSMutableArray *elements = [NSMutableArray array];
    CGFloat cw = [self cellWidthForBounds];
    for (NSUInteger i = 0; i < self.items.count; i++) {
        UIAccessibilityElement *e = [[UIAccessibilityElement alloc] initWithAccessibilityContainer:self];
        e.accessibilityLabel = self.items[i];
        UIAccessibilityTraits traits = UIAccessibilityTraitButton;
        if ((NSInteger)i == self.selectedSegmentIndex) traits |= UIAccessibilityTraitSelected;
        e.accessibilityTraits = traits;
        e.accessibilityFrameInContainerSpace = CGRectMake(cw * (CGFloat)i, 0, cw, self.bounds.size.height);
        [elements addObject:e];
    }
    return elements;
}

@end

#pragma mark - QuotesSaveControl

@interface QuotesSaveControl ()
@property(nonatomic, assign) CGFloat diameter;
@property(nonatomic, strong, nullable) UILabel *wordLabel;
@property(nonatomic, strong) UIView *circle;
@end

@implementation QuotesSaveControl

- (instancetype)initWithDiameter:(CGFloat)diameter showsWord:(BOOL)showsWord {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _diameter = diameter;
        _circle = [[UIView alloc] init];
        _circle.userInteractionEnabled = NO;
        _circle.layer.cornerRadius = diameter / 2;
        _circle.layer.borderWidth = 1.5;
        _circle.layer.borderColor = [QuotesTheme red].CGColor;
        [self addSubview:_circle];
        if (showsWord) {
            _wordLabel = [[UILabel alloc] init];
            _wordLabel.font = [QuotesTheme captionFont];
            _wordLabel.textColor = [QuotesTheme ink];
            _wordLabel.textAlignment = NSTextAlignmentRight;
            _wordLabel.userInteractionEnabled = NO;
            [self addSubview:_wordLabel];
        }
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
        [self refresh];
    }
    return self;
}

- (void)setSaved:(BOOL)saved {
    _saved = saved;
    [self refresh];
}

- (void)setCircleCentered:(BOOL)circleCentered {
    _circleCentered = circleCentered;
    [self setNeedsLayout];
}

- (void)refresh {
    self.circle.backgroundColor = self.saved ? [QuotesTheme red] : [UIColor clearColor];
    self.wordLabel.text = self.saved ? @"Saved" : @"Save";
    self.accessibilityLabel = @"Save";
    self.accessibilityValue = self.saved ? @"Saved" : @"Not saved";
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat d = self.diameter;
    CGFloat cx = self.circleCentered ? (self.bounds.size.width - d) / 2 : self.bounds.size.width - d - 11;
    self.circle.frame = CGRectMake(cx, (self.bounds.size.height - d) / 2, d, d);
    if (self.wordLabel != nil) {
        self.wordLabel.frame = CGRectMake(0, 0, MAX(cx - 10, 0), self.bounds.size.height);
    }
}

@end
