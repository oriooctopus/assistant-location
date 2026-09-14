#import "QuotesBrowseViewController.h"

#import "GLTheme.h"
#import "GLComponents.h"
#import "QuotesStore.h"
#import "QuotesModels.h"

static NSString *const kAllFilterValue = @"All";
static NSString *const kQuoteCellIdentifier = @"QuoteCell";

@interface QuotesBrowseViewController () <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, strong) UIButton *authorFilterButton;
@property(nonatomic, strong) UIButton *genreFilterButton;
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) UIView *emptyStateView;

@property(nonatomic, copy) NSString *authorFilter;   // kAllFilterValue or a real author
@property(nonatomic, copy) NSString *genreFilter;    // kAllFilterValue or a real genre
@property(nonatomic, copy) NSArray<GLQuote *> *allQuotes;
@property(nonatomic, copy) NSArray<GLQuote *> *filteredQuotes;
@end

@implementation QuotesBrowseViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [GLTheme backgroundColor];
    self.authorFilter = kAllFilterValue;
    self.genreFilter = kAllFilterValue;

    [self buildFilterBar];
    [self buildTableView];
    [self reload];
}

#pragma mark - Layout

- (void)buildFilterBar {
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.spacing = [GLTheme spacingXS];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];

    self.authorFilterButton = [self makeFilterButtonWithTitle:@"Author: All"];
    self.genreFilterButton = [self makeFilterButtonWithTitle:@"Genre: All"];
    [stack addArrangedSubview:self.authorFilterButton];
    [stack addArrangedSubview:self.genreFilterButton];

    CGFloat s = [GLTheme spacingM];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:s],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-s],
        [stack.heightAnchor constraintEqualToConstant:[GLTheme controlHeight]],
    ]];
}

- (UIButton *)makeFilterButtonWithTitle:(NSString *)title {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [GLTheme captionFont];
    button.backgroundColor = [GLTheme surfaceColor];
    button.layer.cornerRadius = [GLTheme cornerRadius];
    button.tintColor = [GLTheme textPrimaryColor];
    button.showsMenuAsPrimaryAction = YES;
    return button;
}

- (void)buildTableView {
    UITableView *table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    table.dataSource = self;
    table.delegate = self;
    table.backgroundColor = [GLTheme backgroundColor];
    table.rowHeight = UITableViewAutomaticDimension;
    table.estimatedRowHeight = 72;
    table.translatesAutoresizingMaskIntoConstraints = NO;
    // Not registerClass: a Subtitle-style cell (needed for detailTextLabel
    // to exist at all) can only be produced via -initWithStyle:, which
    // dequeueReusableCellWithIdentifier:forIndexPath:'s registered-class path
    // does not let a caller choose -- see -tableView:cellForRowAtIndexPath:.
    [self.view addSubview:table];
    self.tableView = table;

    [NSLayoutConstraint activateConstraints:@[
        [table.topAnchor constraintEqualToAnchor:self.authorFilterButton.bottomAnchor constant:[GLTheme spacingXS]],
        [table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

#pragma mark - Data

- (void)reload {
    self.allQuotes = [[QuotesStore sharedStore] allQuotes];
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
}

- (void)applyFilters {
    NSMutableArray<GLQuote *> *filtered = [NSMutableArray array];
    for (GLQuote *quote in self.allQuotes) {
        if (![self.authorFilter isEqualToString:kAllFilterValue] && ![quote.author isEqualToString:self.authorFilter]) {
            continue;
        }
        if (![self.genreFilter isEqualToString:kAllFilterValue] && ![quote.genres containsObject:self.genreFilter]) {
            continue;
        }
        [filtered addObject:quote];
    }
    self.filteredQuotes = filtered;
    [self.tableView reloadData];
    [self updateEmptyState];
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
    UIView *empty = [GLComponents emptyStateViewWithMessage:@"No quotes match this filter."];
    empty.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:empty];
    [NSLayoutConstraint activateConstraints:@[
        [empty.centerXAnchor constraintEqualToAnchor:self.tableView.centerXAnchor],
        [empty.centerYAnchor constraintEqualToAnchor:self.tableView.centerYAnchor],
        [empty.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:[GLTheme spacingL]],
        [empty.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-[GLTheme spacingL]],
    ]];
    self.emptyStateView = empty;
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.filteredQuotes.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kQuoteCellIdentifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kQuoteCellIdentifier];
    }
    GLQuote *quote = self.filteredQuotes[(NSUInteger)indexPath.row];

    cell.backgroundColor = [GLTheme backgroundColor];
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.font = [GLTheme bodyFont];
    cell.textLabel.textColor = [GLTheme textPrimaryColor];
    cell.textLabel.text = quote.text;

    cell.detailTextLabel.numberOfLines = 1;
    cell.detailTextLabel.font = [GLTheme captionFont];
    cell.detailTextLabel.textColor = [GLTheme textSecondaryColor];
    NSString *genresJoined = [quote.genres componentsJoinedByString:@", "];
    cell.detailTextLabel.text = genresJoined.length > 0
        ? [NSString stringWithFormat:@"%@ · %@", quote.author, genresJoined]
        : quote.author;

    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
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
        [weakSelf reload];
        if (!saved && weakSelf.view.window != nil) {
            [GLComponents showToastInView:weakSelf.view message:[NSString stringWithFormat:@"Not saved: %@", saveError.localizedDescription ?: @"keychain unavailable"]];
        }
        completionHandler(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[delete]];
}

@end
