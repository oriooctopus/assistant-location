#import "QuotesBrowseViewController.h"

#import "QuotesTheme.h"
#import "Overland-Swift.h" // GLQuotesWidgetReload (Modules/ files are compiled into JournalControl too, so this stays out of QuotesStore.m itself -- see App/QuotesWidgetReload.swift)
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
    self.savedToggle = [[QuotesToggle alloc] initWithItems:@[@"All", @"Saved"]];
    self.savedToggle.cellWidth = 56;
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
        [self.savedToggle.widthAnchor constraintEqualToConstant:112],
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
    self.savedToggle.selectedSegmentIndex = self.savedOnly ? 1 : 0;
}

- (void)savedToggleChanged {
    self.savedOnly = self.savedToggle.selectedSegmentIndex == 1;
    [self refreshFilterButtonTitles];
    [self applyFilters];
}

- (void)applyFilters {
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
    if (self.filteredQuotes.count > 0) {
        if (self.emptyStateView != nil) {
            [self.emptyStateView removeFromSuperview];
            self.emptyStateView = nil;
        }
        return;
    }
    if (self.emptyStateView != nil) return;
    UIView *empty = [QuotesTheme emptyStateViewWithMessage:@"No quotes match this filter."];
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
    return (NSInteger)self.filteredQuotes.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    QuotesBrowseCell *cell = [tableView dequeueReusableCellWithIdentifier:kQuoteCellIdentifier];
    if (cell == nil) {
        cell = [[QuotesBrowseCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kQuoteCellIdentifier];
        [cell.saveControl addTarget:self action:@selector(bookmarkTapped:) forControlEvents:UIControlEventTouchUpInside];
    }
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
    GLQuote *quote = self.filteredQuotes[(NSUInteger)sender.tag];
    NSError *saveError = nil;
    BOOL ok = [[QuotesStore sharedStore] setQuoteId:quote.quoteId
                                              saved:![self.savedIds containsObject:quote.quoteId]
                                              error:&saveError];
    [self reload];
    if (!ok && self.view.window != nil) {
        [QuotesTheme showToastInView:self.view message:[NSString stringWithFormat:@"Not saved: %@", saveError.localizedDescription ?: @"keychain unavailable"]];
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    GLQuote *quote = self.filteredQuotes[(NSUInteger)indexPath.row];
    return [quote.source isEqualToString:GLQuoteSourceImported];
}

- (nullable UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
                 trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
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
