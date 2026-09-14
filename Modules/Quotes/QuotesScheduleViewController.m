#import "QuotesScheduleViewController.h"

#import "GLTheme.h"
#import "GLComponents.h"
#import "QuotesStore.h"
#import "QuotesModels.h"
#import "QuotesRuleEditViewController.h"

static NSString *const kRuleCellIdentifier = @"RuleCell";
static NSString *const kDefaultRotateCellIdentifier = @"DefaultRotateCell";

typedef NS_ENUM(NSInteger, QuotesScheduleSection) {
    QuotesScheduleSectionDefaultRotate = 0,
    QuotesScheduleSectionRules = 1,
};

@interface QuotesScheduleViewController () <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) UIButton *addButton;
@property(nonatomic, strong) UIStepper *defaultRotateStepper;
@property(nonatomic, strong) UILabel *defaultRotateValueLabel;

@property(nonatomic, copy) NSArray<GLQuoteRule *> *rules;
@property(nonatomic, assign) NSInteger defaultRotateMinutes;
@end

@implementation QuotesScheduleViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [GLTheme backgroundColor];
    [self buildTableView];
    [self buildAddButton];
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload]; // a rule can be added/edited by pushing QuotesRuleEditViewController and popping back here
}

#pragma mark - Layout

- (void)buildTableView {
    UITableView *table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    table.dataSource = self;
    table.delegate = self;
    table.backgroundColor = [GLTheme backgroundColor];
    table.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:table];
    self.tableView = table;

    [NSLayoutConstraint activateConstraints:@[
        [table.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
}

- (void)buildAddButton {
    UIButton *button = [GLComponents primaryButtonWithTitle:@"Add Rule"];
    [button addTarget:self action:@selector(addRuleTapped) forControlEvents:UIControlEventTouchUpInside];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:button];
    self.addButton = button;

    CGFloat s = [GLTheme spacingM];
    [NSLayoutConstraint activateConstraints:@[
        [button.topAnchor constraintEqualToAnchor:self.tableView.bottomAnchor constant:[GLTheme spacingXS]],
        [button.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:s],
        [button.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-s],
        [button.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-[GLTheme spacingXS]],
        [button.heightAnchor constraintEqualToConstant:[GLTheme controlHeight]],
    ]];
}

#pragma mark - Data

- (void)reload {
    QuotesStore *store = [QuotesStore sharedStore];
    self.rules = [store rules];
    self.defaultRotateMinutes = [store defaultRotateMinutes];
    [self.tableView reloadData];
}

- (void)addRuleTapped {
    GLQuoteRule *newRule = [[GLQuoteRule alloc] initWithId:[@"rule-" stringByAppendingString:[NSUUID UUID].UUIDString]
                                                        name:@"New Rule"
                                                        kind:GLQuoteRuleKindFilter
                                                     authors:@[]
                                                      genres:@[]
                                                      prompt:@""
                                                    quoteIds:@[]
                                                        days:@[@1, @2, @3, @4, @5, @6, @7]
                                                 startMinute:0
                                                   endMinute:1440
                                               rotateMinutes:self.defaultRotateMinutes];
    QuotesRuleEditViewController *editVC = [[QuotesRuleEditViewController alloc] initWithRule:newRule isNew:YES];
    [self.navigationController pushViewController:editVC animated:YES];
}

#pragma mark - Formatting helpers

+ (NSString *)summaryForDays:(NSArray<NSNumber *> *)days {
    if (days.count == 7) return @"Every day";
    if (days.count == 0) return @"No days selected";
    NSArray<NSString *> *names = @[@"Sun", @"Mon", @"Tue", @"Wed", @"Thu", @"Fri", @"Sat"];
    NSMutableArray<NSString *> *sortedNames = [NSMutableArray array];
    NSArray<NSNumber *> *sorted = [days sortedArrayUsingSelector:@selector(compare:)];
    for (NSNumber *day in sorted) {
        NSInteger idx = day.integerValue - 1;
        if (idx >= 0 && idx < (NSInteger)names.count) [sortedNames addObject:names[(NSUInteger)idx]];
    }
    return [sortedNames componentsJoinedByString:@" "];
}

+ (NSString *)summaryForStartMinute:(NSInteger)start endMinute:(NSInteger)end {
    if (start == 0 && (end == 1440 || end == 0)) return @"All day";
    return [NSString stringWithFormat:@"%02ld:%02ld–%02ld:%02ld", (long)(start / 60), (long)(start % 60), (long)(end / 60), (long)(end % 60)];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == QuotesScheduleSectionDefaultRotate ? 1 : (NSInteger)self.rules.count;
}

- (nullable NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == QuotesScheduleSectionDefaultRotate ? @"Default rotation (no rule matches)" : @"Rules — first match wins";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == QuotesScheduleSectionDefaultRotate) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kDefaultRotateCellIdentifier];
        if (cell == nil) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kDefaultRotateCellIdentifier];
            UIStepper *stepper = [[UIStepper alloc] init];
            stepper.minimumValue = 5;
            stepper.maximumValue = 24 * 60;
            stepper.stepValue = 5;
            [stepper addTarget:self action:@selector(defaultRotateStepperChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = stepper;
            self.defaultRotateStepper = stepper;
        }
        self.defaultRotateStepper.value = self.defaultRotateMinutes;
        cell.textLabel.font = [GLTheme bodyFont];
        cell.textLabel.textColor = [GLTheme textPrimaryColor];
        cell.textLabel.text = [NSString stringWithFormat:@"Every %ld minutes", (long)self.defaultRotateMinutes];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kRuleCellIdentifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kRuleCellIdentifier];
    }
    GLQuoteRule *rule = self.rules[(NSUInteger)indexPath.row];
    cell.textLabel.font = [GLTheme bodyFont];
    cell.textLabel.textColor = [GLTheme textPrimaryColor];
    cell.textLabel.text = rule.name.length > 0 ? rule.name : @"(unnamed rule)";

    NSString *kindLabel = [rule.kind isEqualToString:GLQuoteRuleKindAI] ? @"AI" : @"Filter";
    cell.detailTextLabel.font = [GLTheme captionFont];
    cell.detailTextLabel.textColor = [GLTheme textSecondaryColor];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@ · %@",
        kindLabel,
        [QuotesScheduleViewController summaryForDays:rule.days],
        [QuotesScheduleViewController summaryForStartMinute:rule.startMinute endMinute:rule.endMinute]];

    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == QuotesScheduleSectionRules;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == QuotesScheduleSectionRules;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    NSMutableArray<GLQuoteRule *> *mutableRules = [self.rules mutableCopy];
    [mutableRules removeObjectAtIndex:(NSUInteger)indexPath.row];
    self.rules = mutableRules;
    [[QuotesStore sharedStore] saveRules:self.rules];
    [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath {
    NSMutableArray<GLQuoteRule *> *mutableRules = [self.rules mutableCopy];
    GLQuoteRule *moved = mutableRules[(NSUInteger)sourceIndexPath.row];
    [mutableRules removeObjectAtIndex:(NSUInteger)sourceIndexPath.row];
    [mutableRules insertObject:moved atIndex:(NSUInteger)destinationIndexPath.row];
    self.rules = mutableRules;
    [[QuotesStore sharedStore] saveRules:self.rules];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != QuotesScheduleSectionRules) return;
    GLQuoteRule *rule = self.rules[(NSUInteger)indexPath.row];
    QuotesRuleEditViewController *editVC = [[QuotesRuleEditViewController alloc] initWithRule:rule isNew:NO];
    [self.navigationController pushViewController:editVC animated:YES];
}

#pragma mark - Default rotation stepper

- (void)defaultRotateStepperChanged:(UIStepper *)stepper {
    self.defaultRotateMinutes = (NSInteger)stepper.value;
    [[QuotesStore sharedStore] setDefaultRotateMinutes:self.defaultRotateMinutes];
    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:0 inSection:QuotesScheduleSectionDefaultRotate]]
                           withRowAnimation:UITableViewRowAnimationNone];
}

@end
