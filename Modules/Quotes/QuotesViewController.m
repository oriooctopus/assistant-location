#import "QuotesViewController.h"

#import "GLTheme.h"
#import "QuotesStore.h"
#import "QuotesRuleEngine.h"
#import "QuotesBrowseViewController.h"
#import "QuotesImportViewController.h"
#import "QuotesScheduleViewController.h"

typedef NS_ENUM(NSInteger, QuotesSegment) {
    QuotesSegmentBrowse = 0,
    QuotesSegmentImport = 1,
    QuotesSegmentSchedule = 2,
};

@interface QuotesViewController ()
@property(nonatomic, strong) UIView *unavailableBanner;
@property(nonatomic, strong) UILabel *unavailableBannerLabel;
@property(nonatomic, strong) NSLayoutConstraint *unavailableBannerCollapsedConstraint;
@property(nonatomic, strong) NSLayoutConstraint *previewCardTopToBannerConstraint;
@property(nonatomic, strong) UIView *previewCard;
@property(nonatomic, strong) UILabel *previewCaptionLabel;
@property(nonatomic, strong) UILabel *previewBodyLabel;
@property(nonatomic, strong) UISegmentedControl *segmentedControl;
@property(nonatomic, strong) UIView *containerView;

@property(nonatomic, strong) UIViewController *browseVC;
@property(nonatomic, strong) UIViewController *importVC;
@property(nonatomic, strong) UIViewController *scheduleVC;
@property(nonatomic, strong, nullable) UIViewController *activeChild;
@end

@implementation QuotesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Quotes";
    [GLTheme applyBackgroundToView:self.view];

    [self buildUnavailableBanner];
    [self buildPreviewCard];
    [self buildSegmentedControl];
    [self buildContainer];

    self.browseVC = [[QuotesBrowseViewController alloc] init];
    // Both need to trigger a preview refresh (an import or a schedule edit
    // can change what "right now" resolves to) -- see -reloadPreview and
    // the two delegate-shaped callbacks below.
    self.importVC = [[QuotesImportViewController alloc] init];
    ((QuotesImportViewController *)self.importVC).onQuotesImported = ^{
        // no-op hook point; preview is re-read on every appearance anyway
    };
    self.scheduleVC = [[QuotesScheduleViewController alloc] init];

    [self showChildAtIndex:QuotesSegmentBrowse];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadPreview];
}

#pragma mark - Layout

// Persistent (not auto-dismissing) banner shown above the preview card
// whenever QuotesStore.unavailableError is set -- e.g. the keychain
// entitlement is missing in this build (unsigned CI simulator builds always
// take this path; see QuotesStore.m). Stock quotes stay fully browsable
// underneath it; this only tells the user their imports/rules could not be
// read or saved right now. Collapses to zero height when there's nothing to
// show, via `unavailableBannerCollapsedConstraint` rather than removing/
// re-adding constraints each time.
- (void)buildUnavailableBanner {
    UIView *banner = [[UIView alloc] init];
    banner.backgroundColor = [[GLTheme destructiveColor] colorWithAlphaComponent:0.15];
    banner.layer.cornerRadius = [GLTheme cornerRadius];
    banner.clipsToBounds = YES;
    banner.translatesAutoresizingMaskIntoConstraints = NO;
    banner.hidden = YES;
    [self.view addSubview:banner];
    self.unavailableBanner = banner;

    UILabel *label = [[UILabel alloc] init];
    label.font = [GLTheme captionFont];
    label.textColor = [GLTheme destructiveColor];
    label.numberOfLines = 0;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [banner addSubview:label];
    self.unavailableBannerLabel = label;

    CGFloat s = [GLTheme spacingM];
    CGFloat xs = [GLTheme spacingXS];
    self.unavailableBannerCollapsedConstraint = [banner.heightAnchor constraintEqualToConstant:0];
    self.unavailableBannerCollapsedConstraint.active = YES;

    [NSLayoutConstraint activateConstraints:@[
        [banner.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:[GLTheme spacingS]],
        [banner.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:s],
        [banner.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-s],

        [label.topAnchor constraintEqualToAnchor:banner.topAnchor constant:xs],
        [label.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:xs],
        [label.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-xs],
        [label.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor constant:-xs],
    ]];
}

/// Called after every store read (-reloadPreview) so the banner tracks the
/// live keychain-availability state rather than only reflecting whatever it
/// was when the tab first loaded.
- (void)setUnavailableBannerText:(nullable NSString *)text {
    BOOL shouldShow = text.length > 0;
    self.unavailableBannerLabel.text = text;
    self.unavailableBanner.hidden = !shouldShow;
    self.unavailableBannerCollapsedConstraint.active = !shouldShow;
}

- (void)buildPreviewCard {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [GLTheme surfaceColor];
    card.layer.cornerRadius = [GLTheme cornerRadius];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:card];
    self.previewCard = card;

    UILabel *caption = [[UILabel alloc] init];
    caption.font = [GLTheme captionFont];
    caption.textColor = [GLTheme textSecondaryColor];
    caption.text = @"RIGHT NOW";
    caption.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:caption];
    self.previewCaptionLabel = caption;

    UILabel *body = [[UILabel alloc] init];
    body.font = [GLTheme bodyFont];
    body.textColor = [GLTheme textPrimaryColor];
    body.numberOfLines = 0;
    body.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:body];
    self.previewBodyLabel = body;

    CGFloat s = [GLTheme spacingM];
    self.previewCardTopToBannerConstraint = [card.topAnchor constraintEqualToAnchor:self.unavailableBanner.bottomAnchor constant:[GLTheme spacingS]];
    [NSLayoutConstraint activateConstraints:@[
        self.previewCardTopToBannerConstraint,
        [card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:s],
        [card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-s],

        [caption.topAnchor constraintEqualToAnchor:card.topAnchor constant:s],
        [caption.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:s],
        [caption.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-s],

        [body.topAnchor constraintEqualToAnchor:caption.bottomAnchor constant:[GLTheme spacingXXS]],
        [body.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:s],
        [body.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-s],
        [body.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-s],
    ]];
}

- (void)buildSegmentedControl {
    UISegmentedControl *segmented = [[UISegmentedControl alloc] initWithItems:@[@"Quotes", @"Import", @"Schedule"]];
    segmented.selectedSegmentIndex = QuotesSegmentBrowse;
    [segmented addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    segmented.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:segmented];
    self.segmentedControl = segmented;

    CGFloat s = [GLTheme spacingM];
    [NSLayoutConstraint activateConstraints:@[
        [segmented.topAnchor constraintEqualToAnchor:self.previewCard.bottomAnchor constant:[GLTheme spacingS]],
        [segmented.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:s],
        [segmented.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-s],
    ]];
}

- (void)buildContainer {
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:container];
    self.containerView = container;

    [NSLayoutConstraint activateConstraints:@[
        [container.topAnchor constraintEqualToAnchor:self.segmentedControl.bottomAnchor constant:[GLTheme spacingS]],
        [container.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [container.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [container.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

#pragma mark - Child containment

- (void)segmentChanged:(UISegmentedControl *)sender {
    [self showChildAtIndex:sender.selectedSegmentIndex];
}

- (void)showChildAtIndex:(NSInteger)index {
    UIViewController *next = nil;
    switch ((QuotesSegment)index) {
        case QuotesSegmentBrowse: next = self.browseVC; break;
        case QuotesSegmentImport: next = self.importVC; break;
        case QuotesSegmentSchedule: next = self.scheduleVC; break;
    }
    if (next == nil || next == self.activeChild) return;

    UIViewController *previous = self.activeChild;
    [previous willMoveToParentViewController:nil];
    [previous.view removeFromSuperview];
    [previous removeFromParentViewController];

    [self addChildViewController:next];
    next.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.containerView addSubview:next.view];
    [NSLayoutConstraint activateConstraints:@[
        [next.view.topAnchor constraintEqualToAnchor:self.containerView.topAnchor],
        [next.view.leadingAnchor constraintEqualToAnchor:self.containerView.leadingAnchor],
        [next.view.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor],
        [next.view.bottomAnchor constraintEqualToAnchor:self.containerView.bottomAnchor],
    ]];
    [next didMoveToParentViewController:self];

    self.activeChild = next;

    // Every screen mutates the same store (imported quotes, rules) --
    // reload each time it becomes visible rather than only at first
    // creation, and also refresh the preview since it can be reached from
    // any of the three.
    if ([next respondsToSelector:@selector(reload)]) {
        [(id)next performSelector:@selector(reload)];
    }
    [self reloadPreview];
}

#pragma mark - Preview

- (void)reloadPreview {
    QuotesStore *store = [QuotesStore sharedStore];
    NSArray<GLQuote *> *quotes = [store allQuotes];
    NSArray<GLQuoteRule *> *rules = [store rules];
    NSInteger defaultRotate = [store defaultRotateMinutes];

    // allQuotes/rules/defaultRotateMinutes above each read through the
    // store's keychain document, so unavailableError reflects the latest
    // attempt -- surface it (or clear it) every time this runs.
    NSString *bannerText = store.unavailableError != nil
        ? [NSString stringWithFormat:@"Imported quotes and rules unavailable: %@. Showing stock quotes only.", store.unavailableError.localizedDescription]
        : nil;
    [self setUnavailableBannerText:bannerText];

    NSDate *now = [NSDate date];
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *comps = [calendar components:(NSCalendarUnitWeekday | NSCalendarUnitHour | NSCalendarUnitMinute)
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

    if (selection.awaitingAIResolution) {
        self.previewBodyLabel.text = @"AI resolution coming — this rule's prompt is saved and will be resolved once the server-side matcher ships.";
    } else if (quote == nil) {
        self.previewBodyLabel.text = @"No quotes match the active rule right now.";
    } else {
        self.previewBodyLabel.text = [NSString stringWithFormat:@"“%@”\n— %@", quote.text, quote.author];
    }
}

@end
