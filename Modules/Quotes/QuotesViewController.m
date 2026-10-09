#import "QuotesViewController.h"

#import "QuotesTheme.h"
#import "QuotesStore.h"
#import "QuotesRuleEngine.h"
#import "QuotesDailyNotifier.h"
#import "QuotesBrowseViewController.h"
#import "QuotesImportViewController.h"
#import "QuotesScheduleViewController.h"

// A label that paints the paper colour behind its text (plus a little padding)
// so a grid hairline never runs through it.
@interface QuotesKnockoutLabel : UILabel
@end

@implementation QuotesKnockoutLabel
static const CGFloat kKnockoutPad = 4;
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) self.backgroundColor = [QuotesTheme paper];
    return self;
}
- (void)drawTextInRect:(CGRect)rect {
    [super drawTextInRect:UIEdgeInsetsInsetRect(rect, UIEdgeInsetsMake(0, kKnockoutPad, 0, kKnockoutPad))];
}
- (CGSize)sizeThatFits:(CGSize)size {
    CGSize inner = [super sizeThatFits:CGSizeMake(size.width - 2 * kKnockoutPad, size.height)];
    return CGSizeMake(ceil(inner.width) + 2 * kKnockoutPad, ceil(inner.height));
}
@end

// One quote as the pager shows it: a label per line of the quote (so lines can
// arrive one after another) plus the author and the "0034 / 101" meta line.
// `allViews` is the stagger order: lines top to bottom, then author, then meta.
@interface QuotesPage : NSObject
@property(nonatomic, copy) NSArray<UIView *> *allViews;
@end
@implementation QuotesPage
@end

// Pager tuning. Motion is a pure function of one signed progress value `v`
// (fraction of the screen width the finger has dragged; negative = towards the
// next quote), so the same code serves the live pan, the release spring, a
// tap on "Today" and the screenshot hook.
static const CGFloat kCommitFraction = 0.30;       // pan distance that commits
static const CGFloat kCommitVelocity = 500;        // pt/s flick that commits
static const CGFloat kIncomingTravel = 0.40;       // incoming lines start this fraction of the width away
static const CGFloat kLineStagger = 0.06;          // progress delay per line (about 30ms of the settle)
static const CGFloat kSpringResponse = 0.45;       // seconds
static const CGFloat kSpringDamping = 0.90;        // near critical: no visible overshoot
static const CGFloat kParallax = 7;                // circle nudge, pt
static const CGFloat kDriverScale = 1000;          // driver view x = v * this

@interface QuotesViewController () <UIGestureRecognizerDelegate>
@property(nonatomic, strong) QuotesGridView *gridView;
@property(nonatomic, strong) UILabel *dayLabel;
@property(nonatomic, strong) QuotesKnockoutLabel *dateLabel;
@property(nonatomic, strong) UIView *circleView;
@property(nonatomic, strong) UIView *quoteKnockout;   // paper box, rows 4-6; clips the lines
@property(nonatomic, strong) UIView *metaClip;        // row 7, cols 2-6; clips author + meta
@property(nonatomic, strong) QuotesKnockoutLabel *nextLabel;
@property(nonatomic, strong) QuotesKnockoutLabel *noticeLabel;
@property(nonatomic, strong) QuotesSaveControl *saveControl;
@property(nonatomic, strong) UIButton *todayLink;
@property(nonatomic, copy) NSArray<UIButton *> *navLinks;

// Content
@property(nonatomic, copy) NSArray<GLQuote *> *pagerQuotes;   // same order as Index's All list; empty when there is no quote to show
@property(nonatomic, copy) NSString *messageText;             // shown instead of a quote ("Nothing matches right now.")
@property(nonatomic, assign) NSInteger todayIndex;
@property(nonatomic, assign) NSInteger viewIndex;
@property(nonatomic, assign) NSInteger shownIndex;            // what Save/Today reflect: flips at the half-way point
@property(nonatomic, strong, nullable) GLQuote *currentQuote;

// Pager
@property(nonatomic, strong, nullable) QuotesPage *currentPage;
@property(nonatomic, strong, nullable) QuotesPage *incomingPage;
@property(nonatomic, assign) NSInteger incomingIndex;         // -1 when none
@property(nonatomic, assign) NSInteger incomingSign;          // -1 next, +1 previous, 0 none
@property(nonatomic, assign) CGFloat v;
@property(nonatomic, assign) CGFloat panStartV;
@property(nonatomic, assign) BOOL edgeHapticFired;
@property(nonatomic, strong) UIView *driver;
@property(nonatomic, strong, nullable) UIViewPropertyAnimator *settle;
@property(nonatomic, strong, nullable) CADisplayLink *displayLink;
@property(nonatomic, assign) CGSize pageSize;
@property(nonatomic, assign) CGFloat cellWidth;
@property(nonatomic, assign) BOOL pagesDirty;
@property(nonatomic, strong) UISelectionFeedbackGenerator *selectionHaptic;
@property(nonatomic, strong) UIImpactFeedbackGenerator *edgeHaptic;
@end

@implementation QuotesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Quotes";
    self.incomingIndex = -1;
    self.shownIndex = -1;
    [QuotesTheme styleScreenView:self.view];

    self.gridView = [[QuotesGridView alloc] init];
    [self.view addSubview:self.gridView];

    self.dayLabel = [[UILabel alloc] init];
    self.dayLabel.font = [QuotesTheme fontOfSize:120];
    self.dayLabel.textColor = [QuotesTheme dayGrey];
    self.dayLabel.adjustsFontSizeToFitWidth = YES;
    self.dayLabel.minimumScaleFactor = 0.7;
    self.dayLabel.baselineAdjustment = UIBaselineAdjustmentAlignCenters;
    self.dayLabel.isAccessibilityElement = NO;
    [self.view addSubview:self.dayLabel];

    self.dateLabel = [self makeKnockoutLabelWithColor:[QuotesTheme grey]];
    [self.view addSubview:self.dateLabel];

    self.circleView = [[UIView alloc] init];
    self.circleView.backgroundColor = [QuotesTheme red];
    self.circleView.isAccessibilityElement = NO;
    [self.view addSubview:self.circleView];

    self.quoteKnockout = [[UIView alloc] init];
    self.quoteKnockout.backgroundColor = [QuotesTheme paper];
    self.quoteKnockout.clipsToBounds = YES;
    [self.view addSubview:self.quoteKnockout];

    self.metaClip = [[UIView alloc] init];
    self.metaClip.clipsToBounds = YES;
    [self.view addSubview:self.metaClip];

    self.nextLabel = [self makeKnockoutLabelWithColor:[QuotesTheme grey]];
    [self.view addSubview:self.nextLabel];

    self.noticeLabel = [self makeKnockoutLabelWithColor:[QuotesTheme ink]];
    self.noticeLabel.numberOfLines = 0;
    self.noticeLabel.hidden = YES;
    [self.view addSubview:self.noticeLabel];

    self.saveControl = [[QuotesSaveControl alloc] initWithDiameter:32 showsWord:YES];
    self.saveControl.backgroundColor = [QuotesTheme paper];
    [self.saveControl addTarget:self action:@selector(saveTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.saveControl];

    NSMutableArray<UIButton *> *links = [NSMutableArray array];
    NSArray<NSArray *> *specs = @[@[@"Today", NSStringFromSelector(@selector(todayTapped))],
                                  @[@"Index", NSStringFromSelector(@selector(showIndex))],
                                  @[@"Add", NSStringFromSelector(@selector(showAdd))],
                                  @[@"Rules", NSStringFromSelector(@selector(showRules))]];
    for (NSArray *spec in specs) {
        UIButton *link = [QuotesTheme textLinkWithTitle:spec[0]];
        link.backgroundColor = [QuotesTheme paper];
        [link addTarget:self action:NSSelectorFromString(spec[1]) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:link];
        [links addObject:link];
    }
    self.todayLink = links[0];
    self.todayLink.alpha = 0;
    self.todayLink.userInteractionEnabled = NO;
    self.navLinks = links;

    // Invisible view whose x position carries the pager's progress while it
    // springs: a UIViewPropertyAnimator animates it, a display link reads it.
    self.driver = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
    self.driver.alpha = 0;
    self.driver.userInteractionEnabled = NO;
    [self.view addSubview:self.driver];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    pan.delegate = self;
    [self.view addGestureRecognizer:pan];

    self.selectionHaptic = [[UISelectionFeedbackGenerator alloc] init];
    self.edgeHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleSoft];
}

- (QuotesKnockoutLabel *)makeKnockoutLabelWithColor:(UIColor *)color {
    QuotesKnockoutLabel *label = [[QuotesKnockoutLabel alloc] init];
    label.font = [QuotesTheme captionFont];
    label.textColor = color;
    return label;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadToday];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
#if DEBUG
    [self runSwipeShotHookOnce];
#endif
}

#pragma mark - Navigation

- (void)showIndex { [self.navigationController pushViewController:[[QuotesBrowseViewController alloc] init] animated:YES]; }
- (void)showAdd { [self.navigationController pushViewController:[[QuotesImportViewController alloc] init] animated:YES]; }
- (void)showRules { [self.navigationController pushViewController:[[QuotesScheduleViewController alloc] init] animated:YES]; }

#pragma mark - Layout

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect area = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
    self.gridView.frame = area;
    CGFloat cw = area.size.width / QuotesGridColumns;
    CGFloat ch = area.size.height / QuotesGridRows;
    CGRect (^cell)(NSInteger, NSInteger, NSInteger, NSInteger) = ^CGRect(NSInteger col, NSInteger row, NSInteger cols, NSInteger rows) {
        return CGRectMake(area.origin.x + cw * (col - 1), area.origin.y + ch * (row - 1), cw * cols, ch * rows);
    };

    // Day number across cols 1-2, rows 1-2 (top of the block).
    CGRect dayBox = cell(1, 1, 2, 1);
    self.dayLabel.frame = CGRectMake(dayBox.origin.x + 8, dayBox.origin.y + 4, dayBox.size.width - 8, MIN(ch * 2 - 28, 140));
    CGSize dateSize = [self.dateLabel sizeThatFits:CGSizeMake(cw * 2, 20)];
    CGRect row2 = cell(1, 2, 1, 1);
    self.dateLabel.frame = CGRectMake(row2.origin.x + 4, CGRectGetMaxY(row2) - dateSize.height - 8, dateSize.width, dateSize.height);

    // Decorative circle, one cell on the daily path.
    QuotesGridCell where = QuotesDecorativeCircleCell([NSDate date], [NSCalendar currentCalendar]);
    CGRect circleCell = cell(where.col, where.row, 1, 1);
    CGFloat d = MIN(cw, ch) - 16;
    self.circleView.bounds = CGRectMake(0, 0, d, d);
    self.circleView.center = CGPointMake(CGRectGetMidX(circleCell), CGRectGetMidY(circleCell));
    self.circleView.layer.cornerRadius = d / 2;

    // Quote: a fixed paper knockout over cols 2-6, rows 4-6. Its lines shrink to
    // fit, so the box never changes height and no hairline can cross the text.
    CGRect box = cell(2, 4, 5, 3);
    self.quoteKnockout.frame = box;
    self.metaClip.frame = cell(2, 7, 5, 1);

    CGRect footer = cell(1, 8, 6, 1);
    CGSize nextSize = [self.nextLabel sizeThatFits:CGSizeMake(cw * 3, 20)];
    self.nextLabel.frame = CGRectMake(footer.origin.x + 4, CGRectGetMidY(footer) - nextSize.height / 2, nextSize.width, nextSize.height);
    self.saveControl.frame = cell(5, 8, 2, 1);

    CGRect noticeCell = cell(1, 3, 2, 1);
    CGSize noticeSize = [self.noticeLabel sizeThatFits:CGSizeMake(noticeCell.size.width - 8, noticeCell.size.height)];
    self.noticeLabel.frame = CGRectMake(noticeCell.origin.x + 4, noticeCell.origin.y + 8, noticeSize.width, noticeSize.height);

    // Nav links in the top row, right-aligned, clear of the circle path (row 2+).
    // "Today" owns the leftmost slot, shown only when off today's quote.
    CGFloat x = CGRectGetMaxX(area) - 4;
    for (UIButton *link in [self.navLinks reverseObjectEnumerator]) {
        CGSize s = [link sizeThatFits:CGSizeMake(200, 44)];
        x -= s.width;
        link.frame = CGRectMake(x, area.origin.y, s.width, 44);
    }

    CGSize avail = CGSizeMake(box.size.width - 16, box.size.height - 16);
    if (self.pagesDirty || !CGSizeEqualToSize(avail, self.pageSize)) {
        self.pageSize = avail;
        self.cellWidth = cw;
        [self rebuildPages];
    }
}

#pragma mark - Pages

/// Lays `text` out at the largest size from 28pt down that fits `avail` at 1.35
/// line height, and returns one single-line label per line, centred vertically
/// in the knockout (frames are in knockout coordinates).
- (NSArray<UILabel *> *)lineLabelsForText:(NSString *)text avail:(CGSize)avail {
    const CGFloat pad = 8;
    NSArray<UILabel *> *best = nil;
    for (CGFloat size = 28; size >= 14; size -= 1) {
        CGFloat lineHeight = size * 1.35;
        NSMutableParagraphStyle *wrap = [[NSMutableParagraphStyle alloc] init];
        wrap.alignment = NSTextAlignmentLeft;
        wrap.minimumLineHeight = wrap.maximumLineHeight = lineHeight;
        NSMutableParagraphStyle *clip = [wrap mutableCopy];
        clip.lineBreakMode = NSLineBreakByClipping;
        NSDictionary *attrs = @{NSFontAttributeName: [QuotesTheme fontOfSize:size],
                                NSForegroundColorAttributeName: [QuotesTheme ink]};
        NSMutableAttributedString *whole = [[NSMutableAttributedString alloc] initWithString:text attributes:attrs];
        [whole addAttribute:NSParagraphStyleAttributeName value:wrap range:NSMakeRange(0, whole.length)];

        NSTextStorage *storage = [[NSTextStorage alloc] initWithAttributedString:whole];
        NSLayoutManager *layout = [[NSLayoutManager alloc] init];
        NSTextContainer *container = [[NSTextContainer alloc] initWithSize:CGSizeMake(avail.width, CGFLOAT_MAX)];
        container.lineFragmentPadding = 0;
        [storage addLayoutManager:layout];
        [layout addTextContainer:container];
        [layout ensureLayoutForTextContainer:container];
        CGFloat blockHeight = ceil([layout usedRectForTextContainer:container].size.height);

        NSMutableArray<UILabel *> *labels = [NSMutableArray array];
        CGFloat top = pad + floor((avail.height - blockHeight) / 2);
        [layout enumerateLineFragmentsForGlyphRange:NSMakeRange(0, layout.numberOfGlyphs)
                                         usingBlock:^(CGRect rect, CGRect used, NSTextContainer *tc, NSRange glyphRange, BOOL *stop) {
            NSRange chars = [layout characterRangeForGlyphRange:glyphRange actualGlyphRange:NULL];
            NSMutableAttributedString *sub = [[whole attributedSubstringFromRange:chars] mutableCopy];
            while (sub.length > 0 && [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:[sub.string characterAtIndex:sub.length - 1]]) {
                [sub deleteCharactersInRange:NSMakeRange(sub.length - 1, 1)];
            }
            [sub addAttribute:NSParagraphStyleAttributeName value:clip range:NSMakeRange(0, sub.length)];
            UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(pad, top + rect.origin.y, avail.width, rect.size.height)];
            label.numberOfLines = 1;
            label.attributedText = sub;
            label.isAccessibilityElement = NO;
            [labels addObject:label];
        }];
        best = labels;
        if (blockHeight <= avail.height) break;
    }
    return best;
}

/// Builds the page for quote `index` in the pager (-1: the message page).
/// Its views are not yet in the hierarchy.
- (QuotesPage *)buildPageForIndex:(NSInteger)index {
    NSString *text = self.messageText;
    NSString *author = nil;
    NSString *meta = nil;
    if (index >= 0) {
        GLQuote *quote = self.pagerQuotes[(NSUInteger)index];
        text = quote.text;
        author = quote.author;
        meta = QuotesPageMetaText(index, (NSInteger)self.pagerQuotes.count);
    }
    NSMutableArray<UIView *> *views = [NSMutableArray arrayWithArray:[self lineLabelsForText:text avail:self.pageSize]];
    CGFloat y = 8;
    CGFloat maxWidth = self.cellWidth * 5 - 8;
    for (NSString *string in @[author ?: @"", meta ?: @""]) {
        if (string.length == 0) continue;
        QuotesKnockoutLabel *label = [self makeKnockoutLabelWithColor:[QuotesTheme grey]];
        label.text = string;
        CGSize s = [label sizeThatFits:CGSizeMake(maxWidth, 20)];
        label.frame = CGRectMake(4, y, MIN(s.width, maxWidth), s.height);
        y += s.height + 2;
        [views addObject:label];
    }
    QuotesPage *page = [[QuotesPage alloc] init];
    page.allViews = views;
    return page;
}

- (void)attachPage:(QuotesPage *)page {
    for (UIView *view in page.allViews) {
        [([view isKindOfClass:[QuotesKnockoutLabel class]] ? self.metaClip : self.quoteKnockout) addSubview:view];
    }
}

- (void)detachPage:(QuotesPage *)page {
    for (UIView *view in page.allViews) [view removeFromSuperview];
}

/// Rebuilds the visible page from scratch (new content or new geometry).
- (void)rebuildPages {
    self.pagesDirty = NO;
    [self interruptSettle];
    if (self.incomingPage) [self detachPage:self.incomingPage];
    self.incomingPage = nil;
    self.incomingIndex = -1;
    self.incomingSign = 0;
    if (self.currentPage) [self detachPage:self.currentPage];
    self.v = 0;
    self.currentPage = [self buildPageForIndex:self.viewIndex];
    [self attachPage:self.currentPage];
    self.quoteKnockout.isAccessibilityElement = YES;
    [self applyV];
    [self updateAccessibility];
}

#pragma mark - Content

- (void)reloadToday {
    QuotesStore *store = [QuotesStore sharedStore];
    NSArray<GLQuote *> *quotes = [store allQuotes];
    NSArray<GLQuoteRule *> *rules = [store rules];
    NSInteger defaultRotate = [store defaultRotateMinutes];

    // The reads above go through the keychain document, so unavailableError
    // reflects the latest attempt.
    BOOL unavailable = store.unavailableError != nil;
    self.noticeLabel.text = unavailable ? @"Couldn't reach your library. Showing the stock ones." : nil;
    self.noticeLabel.hidden = !unavailable;

    NSDate *now = [NSDate date];
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *comps = [calendar components:(NSCalendarUnitWeekday | NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitDay)
                                            fromDate:now];
    NSInteger weekday = comps.weekday; // 1 = Sunday, matches GLQuoteRule.days' convention
    NSInteger minuteOfDay = comps.hour * 60 + comps.minute;
    int64_t epochMinute = (int64_t)(now.timeIntervalSince1970 / 60.0);

    QuotesSelection *selection = [QuotesRuleEngine selectionForWeekday:weekday
                                                             minuteOfDay:minuteOfDay
                                                                   rules:rules
                                                                  quotes:quotes
                                                    defaultRotateMinutes:defaultRotate];
    GLQuote *quote = [QuotesRuleEngine currentQuoteForSelection:selection epochMinute:epochMinute];
#if DEBUG
    // Screenshot hook (quotes-shots.yml): pin the quote by id.
    NSString *pinned = NSProcessInfo.processInfo.environment[@"QUOTES_SHOT_QUOTE"];
    if (pinned.length > 0) {
        for (GLQuote *candidate in quotes) if ([candidate.quoteId isEqualToString:pinned]) quote = candidate;
    }
#endif

    NSInteger today = -1;
    if (quote != nil && !selection.awaitingAIResolution) {
        for (NSUInteger i = 0; i < quotes.count; i++) {
            if ([quotes[i].quoteId isEqualToString:quote.quoteId]) { today = (NSInteger)i; break; }
        }
        NSAssert(today >= 0, @"today's quote %@ is not in the library", quote.quoteId);
    }
    self.pagerQuotes = today >= 0 ? quotes : @[];
    self.todayIndex = today;
    self.viewIndex = today;
    self.shownIndex = today;
    self.currentQuote = today >= 0 ? quotes[(NSUInteger)today] : nil;
    if (selection.awaitingAIResolution) {
        self.messageText = @"AI rules: soon.";
    } else if (quote == nil) {
        self.messageText = @"Nothing matches right now.";
    } else {
        self.messageText = quote.text;
    }
    self.saveControl.hidden = today < 0;
    self.todayLink.alpha = 0;
    self.todayLink.userInteractionEnabled = NO;

    self.dayLabel.text = [NSString stringWithFormat:@"%ld", (long)comps.day];
    NSDateFormatter *dateFormat = [[NSDateFormatter alloc] init];
    dateFormat.dateFormat = @"EEEE, MMMM";
    self.dateLabel.text = [dateFormat stringFromDate:now];

    if ([QuotesDailyNotifier isEnabled]) {
        NSInteger m = [QuotesDailyNotifier minuteOfDay];
        NSDateComponents *at = [[NSDateComponents alloc] init];
        at.hour = m / 60;
        at.minute = m % 60;
        NSDateFormatter *timeFormat = [[NSDateFormatter alloc] init];
        timeFormat.dateFormat = @"h:mm a";
        timeFormat.AMSymbol = @"am";
        timeFormat.PMSymbol = @"pm";
        self.nextLabel.text = [NSString stringWithFormat:@"next one %@", [timeFormat stringFromDate:[calendar dateFromComponents:at]]];
    } else {
        self.nextLabel.text = @"daily quote off";
    }

    [self refreshSaved];
    self.pagesDirty = YES;
    [self.view setNeedsLayout];
}

- (void)refreshSaved {
    BOOL saved = self.currentQuote != nil && [[[QuotesStore sharedStore] savedQuoteIds] containsObject:self.currentQuote.quoteId];
#if DEBUG
    if (NSProcessInfo.processInfo.environment[@"QUOTES_SHOT_SAVED"] != nil) saved = YES;
#endif
    self.saveControl.saved = saved;
    self.saveControl.accessibilityHint = self.currentQuote.text;
}

- (void)saveTapped {
    if (self.currentQuote == nil) return;
    NSError *error = nil;
    BOOL ok = [[QuotesStore sharedStore] setQuoteId:self.currentQuote.quoteId saved:!self.saveControl.saved error:&error];
    [self refreshSaved];
    if (!ok) {
        [QuotesTheme showToastInView:self.view message:[NSString stringWithFormat:@"Not saved: %@", error.localizedDescription ?: @"keychain unavailable"]];
    }
}

/// What the screen reader sees and can do: one element for the quote, with
/// next/previous as custom actions (the swipe has no VoiceOver equivalent).
- (void)updateAccessibility {
    NSString *text = self.viewIndex >= 0 ? self.pagerQuotes[(NSUInteger)self.viewIndex].text : self.messageText;
    NSString *author = self.viewIndex >= 0 ? self.pagerQuotes[(NSUInteger)self.viewIndex].author : nil;
    self.quoteKnockout.accessibilityLabel = author.length > 0 ? [NSString stringWithFormat:@"%@ %@", text, author] : text;
    __weak typeof(self) weakSelf = self;
    UIAccessibilityCustomAction *next = [[UIAccessibilityCustomAction alloc] initWithName:@"Next quote" actionHandler:^BOOL(UIAccessibilityCustomAction *a) {
        return [weakSelf animateToIndex:weakSelf.viewIndex + 1];
    }];
    UIAccessibilityCustomAction *previous = [[UIAccessibilityCustomAction alloc] initWithName:@"Previous quote" actionHandler:^BOOL(UIAccessibilityCustomAction *a) {
        return [weakSelf animateToIndex:weakSelf.viewIndex - 1];
    }];
    self.quoteKnockout.accessibilityCustomActions = self.pagerQuotes.count > 1 ? @[next, previous] : @[];
}

#pragma mark - Pager motion

static CGFloat QuotesClamp(CGFloat x, CGFloat lo, CGFloat hi) { return MAX(lo, MIN(hi, x)); }

/// Resistance past the first/last quote: follows the finger, but only ever
/// travels about 60pt.
static CGFloat QuotesRubberBand(CGFloat distance) {
    CGFloat limit = 60, stiffness = 90;
    return (distance < 0 ? -1 : 1) * limit * (1 - 1 / (fabs(distance) / stiffness + 1));
}

/// Draws the pager at progress `v`. Everything else on the screen (grid, day
/// number, nav) is untouched; only the text, and the circle's nudge, move.
- (void)applyV {
    CGFloat width = self.view.bounds.size.width;
    CGFloat v = QuotesClamp(self.v, -1, 1);
    CGFloat magnitude = fabs(v);
    BOOL reduceMotion = UIAccessibilityIsReduceMotionEnabled();
    BOOL hasIncoming = self.incomingPage != nil;

    // Outgoing: follows the finger 1:1 and fades with distance. With nothing to
    // arrive (first/last quote) it rubber-bands instead and stays opaque.
    CGFloat dx = reduceMotion ? 0 : (hasIncoming ? v * width : QuotesRubberBand(v * width));
    CGFloat outgoingAlpha = hasIncoming ? 1 - MIN(1, magnitude / 0.8) : 1;
    for (UIView *view in self.currentPage.allViews) {
        view.transform = CGAffineTransformMakeTranslation(dx, 0);
        view.alpha = outgoingAlpha;
    }

    // Incoming: each element arrives from the opposite side, one after another.
    if (hasIncoming) {
        NSArray<UIView *> *views = self.incomingPage.allViews;
        NSInteger count = (NSInteger)views.count;
        CGFloat step = (reduceMotion || count < 2) ? 0 : MIN(kLineStagger, 0.4 / (count - 1));
        CGFloat spread = 1 - (count - 1) * step;
        CGFloat side = v < 0 ? 1 : -1; // swiping left brings the next quote in from the right
        for (NSInteger j = 0; j < count; j++) {
            CGFloat q = QuotesClamp((magnitude - j * step) / spread, 0, 1);
            views[(NSUInteger)j].transform = CGAffineTransformMakeTranslation(reduceMotion ? 0 : side * kIncomingTravel * width * (1 - q), 0);
            views[(NSUInteger)j].alpha = q;
        }
    }

    // The circle belongs to the date, so it only leans away from the drag and returns.
    CGFloat lean = reduceMotion ? 0 : -(v < 0 ? -1 : 1) * kParallax * sin(M_PI * magnitude);
    self.circleView.transform = CGAffineTransformMakeTranslation(lean, 0);

    // Save and the Today link follow whichever quote is more than half in view.
    NSInteger shown = (hasIncoming && magnitude >= 0.5) ? self.incomingIndex : self.viewIndex;
    if (shown != self.shownIndex) {
        self.shownIndex = shown;
        self.currentQuote = shown >= 0 ? self.pagerQuotes[(NSUInteger)shown] : nil;
        [self refreshSaved];
        BOOL showToday = shown >= 0 && QuotesPageShowsTodayLink(shown, self.todayIndex);
        [UIView animateWithDuration:0.2 animations:^{ self.todayLink.alpha = showToday ? 1 : 0; }];
        self.todayLink.userInteractionEnabled = showToday;
    }
}

/// Points `incoming*` at the quote on the side the drag is heading, building its page.
- (void)updateIncomingForSign:(NSInteger)sign {
    if (sign == self.incomingSign) return;
    if (self.incomingPage) [self detachPage:self.incomingPage];
    self.incomingPage = nil;
    self.incomingIndex = -1;
    self.incomingSign = sign;
    if (sign == 0 || self.viewIndex < 0) return;
    NSInteger delta = sign < 0 ? 1 : -1;
    if (!QuotesPageCanMove(self.viewIndex, delta, (NSInteger)self.pagerQuotes.count)) return;
    self.incomingIndex = QuotesPageIndexAfter(self.viewIndex, delta, (NSInteger)self.pagerQuotes.count);
    self.incomingPage = [self buildPageForIndex:self.incomingIndex];
    [self attachPage:self.incomingPage];
}

- (void)interruptSettle {
    if (self.settle == nil) return;
    CALayer *layer = self.driver.layer.presentationLayer ?: self.driver.layer;
    CGFloat x = layer.position.x;
    [self.settle stopAnimation:YES];
    self.settle = nil;
    [self stopDisplayLink];
    self.driver.layer.position = CGPointMake(x, 0);
    self.v = x / kDriverScale;
}

- (void)startDisplayLink {
    if (self.displayLink) return;
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)stopDisplayLink {
    [self.displayLink invalidate];
    self.displayLink = nil;
}

- (void)tick {
    CALayer *layer = self.driver.layer.presentationLayer ?: self.driver.layer;
    self.v = layer.position.x / kDriverScale;
    [self applyV];
}

/// Springs `v` to `target` (0 = back, +-1 = commit) from the finger's velocity.
/// Interruptible: a new touch calls -interruptSettle and carries on from here.
- (void)settleToTarget:(CGFloat)target velocity:(CGFloat)fractionPerSecond {
    [self interruptSettle];
    self.driver.layer.position = CGPointMake(self.v * kDriverScale, 0);
    UIViewPropertyAnimator *animator;
    if (UIAccessibilityIsReduceMotionEnabled()) {
        animator = [[UIViewPropertyAnimator alloc] initWithDuration:0.2 curve:UIViewAnimationCurveEaseInOut animations:nil];
    } else {
        CGFloat omega = 2 * M_PI / kSpringResponse;
        CGFloat distance = target - self.v;
        CGFloat relativeVelocity = fabs(distance) < 0.001 ? 0 : QuotesClamp(fractionPerSecond / distance, 0, 8);
        UISpringTimingParameters *spring = [[UISpringTimingParameters alloc] initWithMass:1
                                                                                stiffness:omega * omega
                                                                                  damping:2 * kSpringDamping * omega
                                                                          initialVelocity:CGVectorMake(relativeVelocity, 0)];
        animator = [[UIViewPropertyAnimator alloc] initWithDuration:0 timingParameters:spring];
    }
    __weak typeof(self) weakSelf = self;
    [animator addAnimations:^{ weakSelf.driver.center = CGPointMake(target * kDriverScale, 0); }];
    [animator addCompletion:^(UIViewAnimatingPosition position) {
        [weakSelf settledAtTarget:target];
    }];
    self.settle = animator;
    [self startDisplayLink];
    [animator startAnimation];
}

- (void)settledAtTarget:(CGFloat)target {
    self.settle = nil;
    [self stopDisplayLink];
    if (target != 0 && self.incomingPage != nil) {
        [self detachPage:self.currentPage];
        self.currentPage = self.incomingPage;
        self.viewIndex = self.incomingIndex;
        self.incomingPage = nil;
        [self updateAccessibility];
    } else if (self.incomingPage != nil) {
        [self detachPage:self.incomingPage];
        self.incomingPage = nil;
    }
    self.incomingIndex = -1;
    self.incomingSign = 0;
    self.v = 0;
    self.driver.layer.position = CGPointZero;
    [self applyV];
}

#pragma mark - Gestures

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    if (![recognizer isKindOfClass:[UIPanGestureRecognizer class]]) return YES;
    if (self.pagerQuotes.count < 2) return NO;
    CGPoint velocity = [(UIPanGestureRecognizer *)recognizer velocityInView:self.view];
    return fabs(velocity.x) > fabs(velocity.y);
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            [self dragBegan];
            break;
        case UIGestureRecognizerStateChanged:
            [self dragChangedToTranslation:[pan translationInView:self.view].x];
            break;
        case UIGestureRecognizerStateEnded:
            [self dragEndedWithVelocity:[pan velocityInView:self.view].x];
            break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self dragEndedWithVelocity:0];
            break;
        default:
            break;
    }
}

- (void)dragBegan {
    [self interruptSettle];
    self.panStartV = self.v;
    self.edgeHapticFired = NO;
    [self.selectionHaptic prepare];
    [self.edgeHaptic prepare];
}

- (void)dragChangedToTranslation:(CGFloat)translation {
    CGFloat width = self.view.bounds.size.width;
    self.v = QuotesClamp(self.panStartV + translation / width, -1, 1);
    [self updateIncomingForSign:self.v < 0 ? -1 : (self.v > 0 ? 1 : 0)];
    if (self.incomingPage == nil && !self.edgeHapticFired && fabs(self.v) * width > 24) {
        self.edgeHapticFired = YES;
        [self.edgeHaptic impactOccurred];
    }
    [self applyV];
}

- (void)dragEndedWithVelocity:(CGFloat)velocity {
    CGFloat width = self.view.bounds.size.width;
    CGFloat target = 0;
    if (self.incomingPage != nil) {
        CGFloat sign = self.incomingSign;
        BOOL passed = fabs(self.v) > kCommitFraction;
        BOOL flicked = velocity * sign > kCommitVelocity;
        BOOL flungBack = velocity * sign < -kCommitVelocity;
        if ((passed || flicked) && !flungBack) target = sign;
    }
    if (target != 0) [self.selectionHaptic selectionChanged];
    [self settleToTarget:target velocity:velocity / width];
}

#pragma mark - Programmatic moves (Today link, VoiceOver)

/// Animates to quote `index` as a single move, whatever the distance.
- (BOOL)animateToIndex:(NSInteger)index {
    NSInteger count = (NSInteger)self.pagerQuotes.count;
    if (index < 0 || index >= count || index == self.viewIndex) return NO;
    [self interruptSettle];
    if (self.incomingPage) [self detachPage:self.incomingPage];
    self.incomingSign = index > self.viewIndex ? -1 : 1;
    self.incomingIndex = index;
    self.incomingPage = [self buildPageForIndex:index];
    [self attachPage:self.incomingPage];
    [self.selectionHaptic selectionChanged];
    [self settleToTarget:self.incomingSign velocity:0];
    return YES;
}

- (void)todayTapped {
    [self animateToIndex:QuotesPageIndexForTodayTap(self.shownIndex, self.todayIndex)];
}

#if DEBUG
#pragma mark - Screenshot hook

/// QUOTES_SHOT_SWIPE=auto drives the real drag code with synthetic touches:
/// a partial drag that springs back, a committed swipe to the next quote and a
/// committed swipe back. QUOTES_SHOT_SWIPE=<fraction> (e.g. -0.5) holds a drag
/// at that progress for a still.
- (void)runSwipeShotHookOnce {
    NSString *mode = NSProcessInfo.processInfo.environment[@"QUOTES_SHOT_SWIPE"];
    if (mode.length == 0) return;
    static BOOL ran = NO;
    if (ran) return;
    ran = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([mode isEqualToString:@"auto"]) {
            [weakSelf debugDragTo:-0.18 duration:0.5 velocity:0 release:YES then:^{
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [weakSelf debugDragTo:-0.42 duration:0.35 velocity:-300 release:YES then:^{
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            [weakSelf debugDragTo:0.42 duration:0.35 velocity:300 release:YES then:^{}];
                        });
                    }];
                });
            }];
        } else {
            [weakSelf debugDragTo:mode.doubleValue duration:0.3 velocity:0 release:NO then:^{}];
        }
    });
}

- (void)debugDragTo:(CGFloat)fraction duration:(NSTimeInterval)duration velocity:(CGFloat)velocity release:(BOOL)release then:(void (^)(void))done {
    CGFloat width = self.view.bounds.size.width;
    [self dragBegan];
    CFTimeInterval start = CACurrentMediaTime();
    __weak typeof(self) weakSelf = self;
    [NSTimer scheduledTimerWithTimeInterval:1.0 / 120 repeats:YES block:^(NSTimer *timer) {
        CGFloat t = MIN(1, (CACurrentMediaTime() - start) / duration);
        CGFloat eased = t * t * (3 - 2 * t);
        [weakSelf dragChangedToTranslation:fraction * width * eased];
        if (t >= 1) {
            [timer invalidate];
            if (release) [weakSelf dragEndedWithVelocity:velocity];
            done();
        }
    }];
}
#endif

@end
