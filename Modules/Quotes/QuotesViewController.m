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

@interface QuotesViewController ()
@property(nonatomic, strong) QuotesGridView *gridView;
@property(nonatomic, strong) UILabel *dayLabel;
@property(nonatomic, strong) QuotesKnockoutLabel *dateLabel;
@property(nonatomic, strong) UIView *circleView;
@property(nonatomic, strong) UIView *quoteKnockout;
@property(nonatomic, strong) UILabel *quoteLabel;
@property(nonatomic, strong) QuotesKnockoutLabel *authorLabel;
@property(nonatomic, strong) QuotesKnockoutLabel *nextLabel;
@property(nonatomic, strong) QuotesKnockoutLabel *noticeLabel;
@property(nonatomic, strong) QuotesSaveControl *saveControl;
@property(nonatomic, copy) NSArray<UIButton *> *navLinks;

@property(nonatomic, strong, nullable) GLQuote *currentQuote;
@property(nonatomic, copy) NSString *quoteText;
@end

@implementation QuotesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Quotes";
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
    [self.view addSubview:self.quoteKnockout];

    self.quoteLabel = [[UILabel alloc] init];
    self.quoteLabel.numberOfLines = 0;
    self.quoteLabel.textColor = [QuotesTheme ink];
    [self.quoteKnockout addSubview:self.quoteLabel];

    self.authorLabel = [self makeKnockoutLabelWithColor:[QuotesTheme grey]];
    [self.view addSubview:self.authorLabel];

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
    NSArray<NSArray *> *specs = @[@[@"Index", NSStringFromSelector(@selector(showIndex))],
                                  @[@"Add", NSStringFromSelector(@selector(showAdd))],
                                  @[@"Rules", NSStringFromSelector(@selector(showRules))]];
    for (NSArray *spec in specs) {
        UIButton *link = [QuotesTheme textLinkWithTitle:spec[0]];
        link.backgroundColor = [QuotesTheme paper];
        [link addTarget:self action:NSSelectorFromString(spec[1]) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:link];
        [links addObject:link];
    }
    self.navLinks = links;
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
    self.circleView.frame = CGRectMake(CGRectGetMidX(circleCell) - d / 2, CGRectGetMidY(circleCell) - d / 2, d, d);
    self.circleView.layer.cornerRadius = d / 2;

    // Quote: paper knockout over cols 2-6, rows 4-6; text shrinks to fit.
    CGRect box = cell(2, 4, 5, 3);
    self.quoteKnockout.frame = box;
    CGFloat pad = 8;
    CGSize avail = CGSizeMake(box.size.width - 2 * pad, box.size.height - 2 * pad);
    [self fitQuoteInto:avail];
    self.quoteLabel.frame = CGRectMake(pad, pad, avail.width, avail.height);

    CGSize authorSize = [self.authorLabel sizeThatFits:CGSizeMake(cw * 5, 20)];
    CGRect authorCell = cell(2, 7, 1, 1);
    self.authorLabel.frame = CGRectMake(authorCell.origin.x + 4, authorCell.origin.y + 8, MIN(authorSize.width, cw * 5 - 8), authorSize.height);

    CGRect footer = cell(1, 8, 6, 1);
    CGSize nextSize = [self.nextLabel sizeThatFits:CGSizeMake(cw * 3, 20)];
    self.nextLabel.frame = CGRectMake(footer.origin.x + 4, CGRectGetMidY(footer) - nextSize.height / 2, nextSize.width, nextSize.height);
    self.saveControl.frame = cell(5, 8, 2, 1);

    CGRect noticeCell = cell(1, 3, 2, 1);
    CGSize noticeSize = [self.noticeLabel sizeThatFits:CGSizeMake(noticeCell.size.width - 8, noticeCell.size.height)];
    self.noticeLabel.frame = CGRectMake(noticeCell.origin.x + 4, noticeCell.origin.y + 8, noticeSize.width, noticeSize.height);

    // Nav links in the top row, right-aligned, clear of the circle path (row 2+).
    CGFloat x = CGRectGetMaxX(area) - 4;
    for (UIButton *link in [self.navLinks reverseObjectEnumerator]) {
        CGSize s = [link sizeThatFits:CGSizeMake(200, 44)];
        x -= s.width;
        link.frame = CGRectMake(x, area.origin.y, s.width, 44);
    }
}

/// Largest size from 28pt down at which the quote, set at 1.35 line height,
/// fits `avail` (long quotes shrink instead of overflowing the knockout).
- (void)fitQuoteInto:(CGSize)avail {
    if (self.quoteText.length == 0) return;
    NSMutableParagraphStyle *para = [[NSMutableParagraphStyle alloc] init];
    para.alignment = NSTextAlignmentLeft;
    NSAttributedString *fitted = nil;
    for (CGFloat size = 28; size >= 14; size -= 1) {
        para.minimumLineHeight = para.maximumLineHeight = size * 1.35;
        NSAttributedString *attr = [[NSAttributedString alloc] initWithString:self.quoteText attributes:@{
            NSFontAttributeName: [QuotesTheme fontOfSize:size],
            NSForegroundColorAttributeName: [QuotesTheme ink],
            NSParagraphStyleAttributeName: [para copy],
        }];
        CGRect r = [attr boundingRectWithSize:CGSizeMake(avail.width, CGFLOAT_MAX) options:NSStringDrawingUsesLineFragmentOrigin context:nil];
        fitted = attr;
        if (ceil(r.size.height) <= avail.height) break;
    }
    self.quoteLabel.attributedText = fitted;
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
    self.currentQuote = quote;

    if (selection.awaitingAIResolution) {
        self.quoteText = @"AI rules: soon.";
    } else if (quote == nil) {
        self.quoteText = @"Nothing matches right now.";
    } else {
        self.quoteText = quote.text;
    }
    self.authorLabel.text = (quote != nil && !selection.awaitingAIResolution) ? quote.author : nil;
    self.saveControl.hidden = quote == nil || selection.awaitingAIResolution;

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
    self.saveControl.accessibilityHint = quote.text;
    self.quoteLabel.accessibilityLabel = self.quoteText;
    [self.view setNeedsLayout];
}

- (void)refreshSaved {
    BOOL saved = self.currentQuote != nil && [[[QuotesStore sharedStore] savedQuoteIds] containsObject:self.currentQuote.quoteId];
#if DEBUG
    if (NSProcessInfo.processInfo.environment[@"QUOTES_SHOT_SAVED"] != nil) saved = YES;
#endif
    self.saveControl.saved = saved;
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

@end
