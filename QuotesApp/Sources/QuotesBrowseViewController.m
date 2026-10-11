#import "QuotesBrowseViewController.h"

#import "QuotesDailyNotifier.h"
#import "QuotesTheme.h"
#import "QuotesViewController.h"
#import "Overland-Swift.h" // GLQuotesWidgetReload (the QuotesWidget extension compiles QuotesStore.m too, so this stays out of it -- see App/QuotesWidgetReload.swift)
#import "QuotesStore.h"
#import "QuotesModels.h"

static NSString *const kAllFilterValue = @"All";
static NSString *const kQuoteCellIdentifier = @"QuoteCell";

// One index row: grey number in col 1, quote across cols 2-5, save circle in
// col 6 (the six columns are equal slices of the row's width).
@interface QuotesBrowseCell : UITableViewCell
@property(nonatomic, strong) UILabel *numberLabel;
@property(nonatomic, strong) UILabel *quoteLabel;
@property(nonatomic, strong) QuotesSaveControl *saveControl;
@end

@implementation QuotesBrowseCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.backgroundColor = [QuotesTheme paper];
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _numberLabel = [[UILabel alloc] init];
    _numberLabel.font = [QuotesTheme captionFont];
    _numberLabel.textColor = [QuotesTheme grey];
    _numberLabel.isAccessibilityElement = NO;

    _quoteLabel = [[UILabel alloc] init];
    _quoteLabel.font = [QuotesTheme titleFont];
    _quoteLabel.textColor = [QuotesTheme ink];
    _quoteLabel.numberOfLines = 3;

    _saveControl = [[QuotesSaveControl alloc] initWithDiameter:24 showsWord:NO];
    _saveControl.circleCentered = YES;

    for (UIView *v in @[_numberLabel, _quoteLabel, _saveControl]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:v];
    }
    UILayoutGuide *column = [[UILayoutGuide alloc] init]; // one column's width
    [self.contentView addLayoutGuide:column];
    [NSLayoutConstraint activateConstraints:@[
        [column.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [column.widthAnchor constraintEqualToAnchor:self.contentView.widthAnchor multiplier:1.0 / QuotesGridColumns],

        [_numberLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:[QuotesTheme spacingM]],
        [_numberLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:20],

        [_quoteLabel.leadingAnchor constraintEqualToAnchor:column.trailingAnchor constant:4],
        [_quoteLabel.trailingAnchor constraintEqualToAnchor:_saveControl.leadingAnchor constant:-4],
        [_quoteLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:16],
        [_quoteLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-16],

        [_saveControl.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [_saveControl.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [_saveControl.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        [_saveControl.widthAnchor constraintEqualToAnchor:column.widthAnchor],
    ]];
    return self;
}
@end

@interface QuotesBrowseViewController () <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, strong) UIButton *authorFilterButton;
@property(nonatomic, strong) UIButton *genreFilterButton;
@property(nonatomic, strong) QuotesToggle *savedToggle;
@property(nonatomic, strong) UIStackView *filterBar;
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) UIView *footerView;
@property(nonatomic, strong) UILabel *footerCountLabel;
@property(nonatomic, strong) UILabel *footerSavedLabel;
@property(nonatomic, strong) UIView *emptyStateView;

@property(nonatomic, copy) NSString *authorFilter;   // kAllFilterValue or a real author
@property(nonatomic, copy) NSString *genreFilter;    // kAllFilterValue or a real genre
@property(nonatomic, assign) BOOL savedOnly;
@property(nonatomic, assign) BOOL pastMode;                // daily-quote history instead of the library
@property(nonatomic, copy) NSArray<NSDictionary *> *pastEntries; // newest first
@property(nonatomic, copy) NSArray<NSString *> *savedIds; // newest first
@property(nonatomic, copy) NSArray<GLQuote *> *allQuotes;
@property(nonatomic, copy) NSArray<GLQuote *> *filteredQuotes;
@end

@implementation QuotesBrowseViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [QuotesTheme styleScreenView:self.view];
    [QuotesTheme installBackLinkInViewController:self];
    self.authorFilter = kAllFilterValue;
    self.genreFilter = kAllFilterValue;
#if DEBUG
    // Screenshot hook (quotes-shots.yml): open on the Saved filter.
    self.savedOnly = NSProcessInfo.processInfo.environment[@"QUOTES_SHOT_SAVED_ONLY"] != nil;
    self.pastMode = NSProcessInfo.processInfo.environment[@"QUOTES_SHOT_PAST"] != nil;
#endif

    [self buildFilterBar];
    [self buildFooter];
    [self buildTableView];
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload]; // a notification's Save action may have changed the saved list while we were away
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    CGColorRef border = [[QuotesTheme hairline] resolvedColorWithTraitCollection:self.traitCollection].CGColor;
    self.authorFilterButton.layer.borderColor = border;
    self.genreFilterButton.layer.borderColor = border;
}

#pragma mark - Layout

- (void)buildFilterBar {
    self.savedToggle = [[QuotesToggle alloc] initWithItems:@[@"All", @"Saved", @"Past"]];
    self.savedToggle.cellWidth = 52;
    [self.savedToggle addTarget:self action:@selector(savedToggleChanged) forControlEvents:UIControlEventValueChanged];

    self.authorFilterButton = [self makeFilterButtonWithTitle:@"Author: All"];
    self.genreFilterButton = [self makeFilterButtonWithTitle:@"Genre: All"];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.savedToggle, self.authorFilterButton, self.genreFilterButton]];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = [QuotesTheme spacingXS];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    self.filterBar = stack;

    CGFloat s = [QuotesTheme spacingM];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:[QuotesTheme spacingS]],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:s],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-s],
        [stack.heightAnchor constraintEqualToConstant:36],
        [self.savedToggle.widthAnchor constraintEqualToConstant:156],
        [self.authorFilterButton.widthAnchor constraintEqualToAnchor:self.genreFilterButton.widthAnchor],
    ]];
}

- (UIButton *)makeFilterButtonWithTitle:(NSString *)title {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [QuotesTheme buttonFont];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.8;
    [button setTitleColor:[QuotesTheme grey] forState:UIControlStateNormal];
    button.backgroundColor = [QuotesTheme paper];
    button.layer.cornerRadius = 0;
    button.layer.borderWidth = 0.5;
    button.layer.borderColor = [[QuotesTheme hairline] resolvedColorWithTraitCollection:self.traitCollection].CGColor;
    button.showsMenuAsPrimaryAction = YES;
    return button;
}

- (void)buildFooter {
    UIView *footer = [[UIView alloc] init];
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    footer.backgroundColor = [QuotesTheme paper];
    [self.view addSubview:footer];
    self.footerView = footer;

    UIView *rule = [[UIView alloc] init];
    rule.backgroundColor = [QuotesTheme hairline];
    rule.translatesAutoresizingMaskIntoConstraints = NO;
    [footer addSubview:rule];

    self.footerCountLabel = [self footerLabelAligned:NSTextAlignmentLeft];
    self.footerSavedLabel = [self footerLabelAligned:NSTextAlignmentRight];
    [footer addSubview:self.footerCountLabel];
    [footer addSubview:self.footerSavedLabel];

    CGFloat s = [QuotesTheme spacingM];
    [NSLayoutConstraint activateConstraints:@[
        [footer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [footer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [footer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [footer.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-40],
        [rule.topAnchor constraintEqualToAnchor:footer.topAnchor],
        [rule.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor],
        [rule.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor],
        [rule.heightAnchor constraintEqualToConstant:0.5],
        [self.footerCountLabel.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:s],
        [self.footerCountLabel.topAnchor constraintEqualToAnchor:footer.topAnchor constant:12],
        [self.footerSavedLabel.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-s],
        [self.footerSavedLabel.topAnchor constraintEqualToAnchor:footer.topAnchor constant:12],
    ]];
}

- (UILabel *)footerLabelAligned:(NSTextAlignment)alignment {
    UILabel *label = [[UILabel alloc] init];
    label.font = [QuotesTheme captionFont];
    label.textColor = [QuotesTheme grey];
    label.textAlignment = alignment;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

- (void)buildTableView {
    UITableView *table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    table.dataSource = self;
    table.delegate = self;
    table.backgroundColor = [QuotesTheme paper];
    table.separatorColor = [QuotesTheme hairline];
    table.separatorInset = UIEdgeInsetsZero;
    table.rowHeight = UITableViewAutomaticDimension;
    table.estimatedRowHeight = 88;
    table.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view insertSubview:table belowSubview:self.footerView];
    self.tableView = table;

    [NSLayoutConstraint activateConstraints:@[
        [table.topAnchor constraintEqualToAnchor:self.filterBar.bottomAnchor constant:[QuotesTheme spacingS]],
        [table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [table.bottomAnchor constraintEqualToAnchor:self.footerView.topAnchor],
    ]];
}

#pragma mark - Data

- (void)reload {
    self.allQuotes = [[QuotesStore sharedStore] allQuotes];
    self.savedIds = [[QuotesStore sharedStore] savedQuoteIds];
    self.pastEntries = [QuotesDailyNotifier history];
#if DEBUG
    if (NSProcessInfo.processInfo.environment[@"QUOTES_SHOT_PAST"] != nil) {
        // Screenshot hook: fake history (in memory only), one entry whose quote no longer exists.
        NSMutableArray *seeded = [NSMutableArray array];
        NSArray *dates = @[@"2026-10-11", @"2026-10-10", @"2026-10-09", @"2026-10-08"];
        for (NSUInteger i = 0; i < dates.count && i < self.allQuotes.count; i++) {
            GLQuote *q = self.allQuotes[i * 3];
            BOOL gone = i == 2;
            [seeded addObject:@{@"date": dates[i], @"fire": @0, @"quoteId": gone ? @"deleted-quote" : q.quoteId, @"text": q.text, @"author": q.author ?: @""}];
        }
        self.pastEntries = seeded;
    }
#endif
    [self rebuildFilterMenus];
    [self applyFilters];
}

- (void)rebuildFilterMenus {
    NSArray<NSString *> *authors = [[QuotesStore sharedStore] knownAuthors];
    NSArray<NSString *> *genres = [[QuotesStore sharedStore] knownGenres];

    __weak typeof(self) weakSelf = self;
    self.authorFilterButton.menu = [self menuForOptions:authors
                                                  current:self.authorFilter
                                                    title:@"Author"
                                               onSelected:^(NSString *value) {
        weakSelf.authorFilter = value;
        [weakSelf refreshFilterButtonTitles];
        [weakSelf applyFilters];
    }];
    self.genreFilterButton.menu = [self menuForOptions:genres
                                                 current:self.genreFilter
                                                   title:@"Genre"
                                              onSelected:^(NSString *value) {
        weakSelf.genreFilter = value;
        [weakSelf refreshFilterButtonTitles];
        [weakSelf applyFilters];
    }];
    [self refreshFilterButtonTitles];
}

- (UIMenu *)menuForOptions:(NSArray<NSString *> *)options
                    current:(NSString *)current
                      title:(NSString *)title
                 onSelected:(void (^)(NSString *value))onSelected {
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
    NSArray<NSString *> *allValues = [@[kAllFilterValue] arrayByAddingObjectsFromArray:options];
    for (NSString *value in allValues) {
        UIAction *action = [UIAction actionWithTitle:value
                                                image:nil
                                           identifier:nil
                                              handler:^(__kindof UIAction *action) {
            onSelected(value);
        }];
        action.state = [value isEqualToString:current] ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }
    return [UIMenu menuWithTitle:title children:actions];
}

- (void)refreshFilterButtonTitles {
    [self.authorFilterButton setTitle:[NSString stringWithFormat:@"Author: %@", self.authorFilter]
                              forState:UIControlStateNormal];
    [self.genreFilterButton setTitle:[NSString stringWithFormat:@"Genre: %@", self.genreFilter]
                             forState:UIControlStateNormal];
    BOOL authorOn = ![self.authorFilter isEqualToString:kAllFilterValue];
    BOOL genreOn = ![self.genreFilter isEqualToString:kAllFilterValue];
    [self.authorFilterButton setTitleColor:authorOn ? [QuotesTheme ink] : [QuotesTheme grey] forState:UIControlStateNormal];
    [self.genreFilterButton setTitleColor:genreOn ? [QuotesTheme ink] : [QuotesTheme grey] forState:UIControlStateNormal];
    self.savedToggle.selectedSegmentIndex = self.pastMode ? 2 : (self.savedOnly ? 1 : 0);
    self.authorFilterButton.hidden = self.pastMode; // filters don't apply to history
    self.genreFilterButton.hidden = self.pastMode;
}

- (void)savedToggleChanged {
    self.savedOnly = self.savedToggle.selectedSegmentIndex == 1;
    self.pastMode = self.savedToggle.selectedSegmentIndex == 2;
    [self refreshFilterButtonTitles];
    [self applyFilters];
}

- (void)applyFilters {
    if (self.pastMode) {
        self.filteredQuotes = @[];
        [self.tableView reloadData];
        [self updateEmptyState];
        self.footerCountLabel.text = [NSString stringWithFormat:@"%lu past.", (unsigned long)self.pastEntries.count];
        self.footerSavedLabel.text = [NSString stringWithFormat:@"%lu saved.", (unsigned long)self.savedIds.count];
        return;
    }
    NSMutableArray<GLQuote *> *filtered = [NSMutableArray array];
    for (GLQuote *quote in self.allQuotes) {
        if (self.savedOnly && ![self.savedIds containsObject:quote.quoteId]) continue;
        if (![self.authorFilter isEqualToString:kAllFilterValue] && ![quote.author isEqualToString:self.authorFilter]) {
            continue;
        }
        if (![self.genreFilter isEqualToString:kAllFilterValue] && ![quote.genres containsObject:self.genreFilter]) {
            continue;
        }
        [filtered addObject:quote];
    }
    if (self.savedOnly) {
        // Newest saved first, matching the store's order.
        [filtered sortUsingComparator:^NSComparisonResult(GLQuote *a, GLQuote *b) {
            return [@([self.savedIds indexOfObject:a.quoteId]) compare:@([self.savedIds indexOfObject:b.quoteId])];
        }];
    }
    self.filteredQuotes = filtered;
    [self.tableView reloadData];
    [self updateEmptyState];
    self.footerCountLabel.text = [NSString stringWithFormat:@"%lu of %lu", (unsigned long)filtered.count, (unsigned long)self.allQuotes.count];
    self.footerSavedLabel.text = [NSString stringWithFormat:@"%lu saved.", (unsigned long)self.savedIds.count];
}

- (void)updateEmptyState {
    [self.emptyStateView removeFromSuperview];
    self.emptyStateView = nil;
    if ([self rowCount] > 0) return;
    UIView *empty = [QuotesTheme emptyStateViewWithMessage:self.pastMode ? @"No daily quotes yet." : @"No quotes match this filter."];
    empty.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:empty];
    [NSLayoutConstraint activateConstraints:@[
        [empty.centerXAnchor constraintEqualToAnchor:self.tableView.centerXAnchor],
        [empty.centerYAnchor constraintEqualToAnchor:self.tableView.centerYAnchor],
        [empty.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:[QuotesTheme spacingL]],
        [empty.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-[QuotesTheme spacingL]],
    ]];
    self.emptyStateView = empty;
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)[self rowCount];
}

- (NSUInteger)rowCount {
    return self.pastMode ? self.pastEntries.count : self.filteredQuotes.count;
}

// "yyyy-MM-dd" -> "Sun,\nOct 11" (two lines: the number column is narrow).
- (NSString *)displayDateForPastDate:(NSString *)date {
    static NSDateFormatter *parser, *display;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        parser = [[NSDateFormatter alloc] init];
        parser.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        parser.dateFormat = @"yyyy-MM-dd";
        display = [[NSDateFormatter alloc] init];
        display.dateFormat = @"EEE,\nMMM d";
    });
    NSDate *parsed = [parser dateFromString:date];
    if (parsed == nil) [NSException raise:NSInternalInconsistencyException format:@"bad history date %@", date];
    return [display stringFromDate:parsed];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    if (!self.pastMode) return;
    NSString *quoteId = self.pastEntries[(NSUInteger)indexPath.row][@"quoteId"];
    [(QuotesViewController *)self.navigationController.viewControllers.firstObject openQuoteWithId:quoteId];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    QuotesBrowseCell *cell = [tableView dequeueReusableCellWithIdentifier:kQuoteCellIdentifier];
    if (cell == nil) {
        cell = [[QuotesBrowseCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kQuoteCellIdentifier];
        [cell.saveControl addTarget:self action:@selector(bookmarkTapped:) forControlEvents:UIControlEventTouchUpInside];
    }
    if (self.pastMode) {
        NSDictionary *entry = self.pastEntries[(NSUInteger)indexPath.row];
        NSString *quoteId = entry[@"quoteId"];
        BOOL exists = NO;
        for (GLQuote *q in self.allQuotes) if ([q.quoteId isEqualToString:quoteId]) { exists = YES; break; }
        cell.numberLabel.text = [self displayDateForPastDate:entry[@"date"]];
        cell.numberLabel.numberOfLines = 2;
        cell.quoteLabel.text = entry[@"text"];
        cell.quoteLabel.accessibilityHint = entry[@"author"];
        cell.saveControl.hidden = !exists;
        cell.saveControl.saved = exists && [self.savedIds containsObject:quoteId];
        cell.saveControl.tag = indexPath.row;
        return cell;
    }
    cell.numberLabel.numberOfLines = 1;
    cell.saveControl.hidden = NO;
    GLQuote *quote = self.filteredQuotes[(NSUInteger)indexPath.row];
    NSUInteger libraryIndex = [self.allQuotes indexOfObject:quote];
    cell.numberLabel.text = [NSString stringWithFormat:@"%04lu", (unsigned long)libraryIndex + 1];
    cell.quoteLabel.text = quote.text;
    cell.quoteLabel.accessibilityHint = quote.author;
    BOOL saved = [self.savedIds containsObject:quote.quoteId];
#if DEBUG
    if (NSProcessInfo.processInfo.environment[@"QUOTES_SHOT_SAVED"] != nil && indexPath.row % 2 == 0) saved = YES;
#endif
    cell.saveControl.saved = saved;
    cell.saveControl.tag = indexPath.row;
    return cell;
}

- (void)bookmarkTapped:(QuotesSaveControl *)sender {
    NSString *quoteId = self.pastMode ? self.pastEntries[(NSUInteger)sender.tag][@"quoteId"] : self.filteredQuotes[(NSUInteger)sender.tag].quoteId;
    NSError *saveError = nil;
    BOOL ok = [[QuotesStore sharedStore] setQuoteId:quoteId
                                              saved:![self.savedIds containsObject:quoteId]
                                              error:&saveError];
    [self reload];
    if (!ok && self.view.window != nil) {
        [QuotesTheme showToastInView:self.view message:[NSString stringWithFormat:@"Not saved: %@", saveError.localizedDescription ?: @"keychain unavailable"]];
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.pastMode) return NO;
    GLQuote *quote = self.filteredQuotes[(NSUInteger)indexPath.row];
    return [quote.source isEqualToString:GLQuoteSourceImported];
}

- (nullable UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
                 trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.pastMode) return nil;
    GLQuote *quote = self.filteredQuotes[(NSUInteger)indexPath.row];
    if (![quote.source isEqualToString:GLQuoteSourceImported]) return nil; // stock quotes aren't deletable

    __weak typeof(self) weakSelf = self;
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                            title:@"Delete"
                                                                          handler:^(UIContextualAction *action, __kindof UIView *sourceView, void (^completionHandler)(BOOL)) {
        NSError *saveError = nil;
        BOOL saved = [[QuotesStore sharedStore] deleteImportedQuoteWithId:quote.quoteId error:&saveError];
        if (saved) [GLQuotesWidgetReload reloadAllTimelines]; // the widget's pool changed -- see App/QuotesWidgetReload.swift
        [weakSelf reload];
        if (!saved && weakSelf.view.window != nil) {
            [QuotesTheme showToastInView:weakSelf.view message:[NSString stringWithFormat:@"Not saved: %@", saveError.localizedDescription ?: @"keychain unavailable"]];
        }
        completionHandler(YES);
    }];
    delete.backgroundColor = [QuotesTheme ink];
    return [UISwipeActionsConfiguration configurationWithActions:@[delete]];
}

@end
