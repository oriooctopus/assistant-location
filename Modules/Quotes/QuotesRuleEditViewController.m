#import "QuotesRuleEditViewController.h"

#import "GLTheme.h"
#import "GLComponents.h"
#import "GLHaptics.h"
#import "QuotesStore.h"
#import "QuotesAIFilterClient.h"

/// One row in a checkbox list (authors/genres): a label plus a checkmark
/// that toggles on tap. Built with a UITapGestureRecognizer rather than a
/// UIButton so the whole row (not just the checkmark glyph) is tappable.
@interface QuotesCheckboxRow : UIView
@property(nonatomic, copy) NSString *value;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, strong) UIImageView *checkmark;
@property(nonatomic, copy) void (^onToggle)(NSString *value);
@end

@implementation QuotesCheckboxRow

- (instancetype)initWithValue:(NSString *)value selected:(BOOL)selected onToggle:(void (^)(NSString *))onToggle {
    self = [super init];
    if (self) {
        self.value = value;
        self.onToggle = onToggle;
        self.translatesAutoresizingMaskIntoConstraints = NO;

        self.label = [[UILabel alloc] init];
        self.label.text = value;
        self.label.font = [GLTheme bodyFont];
        self.label.textColor = [GLTheme textPrimaryColor];
        self.label.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:self.label];

        self.checkmark = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle.fill"]];
        self.checkmark.tintColor = [GLTheme accentColor];
        self.checkmark.hidden = !selected;
        self.checkmark.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:self.checkmark];

        [NSLayoutConstraint activateConstraints:@[
            [self.heightAnchor constraintEqualToConstant:40],
            [self.label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:[GLTheme spacingS]],
            [self.label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [self.checkmark.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-[GLTheme spacingS]],
            [self.checkmark.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [self.checkmark.widthAnchor constraintEqualToConstant:20],
            [self.checkmark.heightAnchor constraintEqualToConstant:20],
            [self.label.trailingAnchor constraintLessThanOrEqualToAnchor:self.checkmark.leadingAnchor constant:-[GLTheme spacingXS]],
        ]];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped)];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)tapped {
    self.checkmark.hidden = !self.checkmark.hidden;
    if (self.onToggle != nil) self.onToggle(self.value);
}

@end

// Fixed genre vocabulary, matching stock-quotes.json's own set — see the
// Quotes brief.
static NSArray<NSString *> *QuotesFixedGenres(void) {
    return @[@"stoicism", @"motivation", @"love", @"humor", @"wisdom", @"creativity", @"philosophy", @"courage", @"life", @"work"];
}

@interface QuotesRuleEditViewController ()
@property(nonatomic, strong) GLQuoteRule *rule;
@property(nonatomic, assign) BOOL isNew;
@property(nonatomic, copy) NSString *originalPrompt; // to detect "changed" on Save, per the AI auto-resolve rule

@property(nonatomic, strong) UIScrollView *scrollView;
@property(nonatomic, strong) UIStackView *stack;

@property(nonatomic, strong) UITextField *nameField;
@property(nonatomic, strong) UISegmentedControl *kindControl;

@property(nonatomic, strong) UIView *filterSection;
@property(nonatomic, strong) UIStackView *authorsStack;
@property(nonatomic, strong) UIStackView *genresStack;
@property(nonatomic, strong) NSMutableSet<NSString *> *selectedAuthors;
@property(nonatomic, strong) NSMutableSet<NSString *> *selectedGenres;

@property(nonatomic, strong) UIView *aiSection;
@property(nonatomic, strong) UITextView *promptField;
@property(nonatomic, strong) UIButton *rerunButton;
@property(nonatomic, strong) UIActivityIndicatorView *aiSpinner;
@property(nonatomic, strong) UILabel *aiStatusLabel;
@property(nonatomic, strong) NSMutableArray<NSString *> *resolvedQuoteIds;

@property(nonatomic, strong) NSMutableArray<UIButton *> *dayButtons;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *selectedDays;

@property(nonatomic, strong) UIDatePicker *startPicker;
@property(nonatomic, strong) UIDatePicker *endPicker;
@property(nonatomic, strong) UIStepper *rotateStepper;
@property(nonatomic, strong) UILabel *rotateValueLabel;

@property(nonatomic, strong) UIButton *saveButton;
@end

@implementation QuotesRuleEditViewController

- (instancetype)initWithRule:(GLQuoteRule *)rule isNew:(BOOL)isNew {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _rule = [rule copy];
        _isNew = isNew;
        _originalPrompt = [rule.prompt copy];
        _selectedAuthors = [NSMutableSet setWithArray:rule.authors];
        _selectedGenres = [NSMutableSet setWithArray:rule.genres];
        _selectedDays = [NSMutableSet setWithArray:rule.days];
        _resolvedQuoteIds = [rule.quoteIds mutableCopy];
        _dayButtons = [NSMutableArray array];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.isNew ? @"New Rule" : @"Edit Rule";
    self.view.backgroundColor = [GLTheme backgroundColor];

    [self buildScrollingForm];
    [self buildNameField];
    [self buildKindControl];
    [self buildFilterSection];
    [self buildAISection];
    [self buildDaysRow];
    [self buildTimeRows];
    [self buildRotateRow];
    [self buildSaveButton];

    [self updateKindVisibility];
    [self updateAIStatusLabel];
}

#pragma mark - Scaffolding

- (void)buildScrollingForm {
    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    self.scrollView = scroll;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = [GLTheme spacingM];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    self.stack = stack;

    CGFloat s = [GLTheme spacingM];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [stack.topAnchor constraintEqualToAnchor:scroll.topAnchor constant:s],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor constant:s],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor constant:-s],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:-s],
        [stack.widthAnchor constraintEqualToAnchor:scroll.widthAnchor constant:-(s * 2)],
    ]];
}

- (UILabel *)sectionLabelWithTitle:(NSString *)title {
    UILabel *label = [[UILabel alloc] init];
    label.text = title;
    label.font = [GLTheme captionFont];
    label.textColor = [GLTheme textSecondaryColor];
    return label;
}

- (void)buildNameField {
    [self.stack addArrangedSubview:[self sectionLabelWithTitle:@"NAME"]];
    UITextField *field = [[UITextField alloc] init];
    field.text = self.rule.name;
    field.font = [GLTheme bodyFont];
    field.textColor = [GLTheme textPrimaryColor];
    field.backgroundColor = [GLTheme surfaceColor];
    field.layer.cornerRadius = [GLTheme cornerRadius];
    field.borderStyle = UITextBorderStyleNone;
    UIView *padding = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 0)];
    field.leftView = padding;
    field.leftViewMode = UITextFieldViewModeAlways;
    [field.heightAnchor constraintEqualToConstant:[GLTheme controlHeight]].active = YES;
    [self.stack addArrangedSubview:field];
    self.nameField = field;
}

- (void)buildKindControl {
    [self.stack addArrangedSubview:[self sectionLabelWithTitle:@"KIND"]];
    UISegmentedControl *control = [[UISegmentedControl alloc] initWithItems:@[@"Filter (authors/genres)", @"AI (prompt)"]];
    control.selectedSegmentIndex = [self.rule.kind isEqualToString:GLQuoteRuleKindAI] ? 1 : 0;
    [control addTarget:self action:@selector(kindChanged) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:control];
    self.kindControl = control;
}

- (void)kindChanged {
    [self updateKindVisibility];
}

- (void)updateKindVisibility {
    BOOL isAI = self.kindControl.selectedSegmentIndex == 1;
    self.filterSection.hidden = isAI;
    self.aiSection.hidden = !isAI;
}

#pragma mark - Filter section (authors/genres)

- (void)buildFilterSection {
    UIView *section = [[UIView alloc] init];
    [self.stack addArrangedSubview:section];
    self.filterSection = section;

    UIStackView *inner = [[UIStackView alloc] init];
    inner.axis = UILayoutConstraintAxisVertical;
    inner.spacing = [GLTheme spacingS];
    inner.translatesAutoresizingMaskIntoConstraints = NO;
    [section addSubview:inner];
    [NSLayoutConstraint activateConstraints:@[
        [inner.topAnchor constraintEqualToAnchor:section.topAnchor],
        [inner.leadingAnchor constraintEqualToAnchor:section.leadingAnchor],
        [inner.trailingAnchor constraintEqualToAnchor:section.trailingAnchor],
        [inner.bottomAnchor constraintEqualToAnchor:section.bottomAnchor],
    ]];

    [inner addArrangedSubview:[self sectionLabelWithTitle:@"AUTHORS (matches ANY selected, plus any selected genre)"]];
    UIStackView *authorsStack = [[UIStackView alloc] init];
    authorsStack.axis = UILayoutConstraintAxisVertical;
    authorsStack.spacing = 0;
    authorsStack.backgroundColor = [GLTheme surfaceColor];
    authorsStack.layer.cornerRadius = [GLTheme cornerRadius];
    authorsStack.layoutMarginsRelativeArrangement = YES;
    [inner addArrangedSubview:authorsStack];
    self.authorsStack = authorsStack;

    [inner addArrangedSubview:[self sectionLabelWithTitle:@"GENRES"]];
    UIStackView *genresStack = [[UIStackView alloc] init];
    genresStack.axis = UILayoutConstraintAxisVertical;
    genresStack.spacing = 0;
    genresStack.backgroundColor = [GLTheme surfaceColor];
    genresStack.layer.cornerRadius = [GLTheme cornerRadius];
    genresStack.layoutMarginsRelativeArrangement = YES;
    [inner addArrangedSubview:genresStack];
    self.genresStack = genresStack;

    [self populateAuthorsAndGenres];
}

- (void)populateAuthorsAndGenres {
    for (UIView *v in self.authorsStack.arrangedSubviews) [v removeFromSuperview];
    for (UIView *v in self.genresStack.arrangedSubviews) [v removeFromSuperview];

    __weak typeof(self) weakSelf = self;
    NSArray<NSString *> *authors = [[QuotesStore sharedStore] knownAuthors];
    for (NSString *author in authors) {
        QuotesCheckboxRow *row = [[QuotesCheckboxRow alloc] initWithValue:author
                                                                    selected:[self.selectedAuthors containsObject:author]
                                                                    onToggle:^(NSString *value) {
            if ([weakSelf.selectedAuthors containsObject:value]) {
                [weakSelf.selectedAuthors removeObject:value];
            } else {
                [weakSelf.selectedAuthors addObject:value];
            }
        }];
        [self.authorsStack addArrangedSubview:row];
    }

    for (NSString *genre in QuotesFixedGenres()) {
        QuotesCheckboxRow *row = [[QuotesCheckboxRow alloc] initWithValue:genre
                                                                    selected:[self.selectedGenres containsObject:genre]
                                                                    onToggle:^(NSString *value) {
            if ([weakSelf.selectedGenres containsObject:value]) {
                [weakSelf.selectedGenres removeObject:value];
            } else {
                [weakSelf.selectedGenres addObject:value];
            }
        }];
        [self.genresStack addArrangedSubview:row];
    }
}

#pragma mark - AI section

- (void)buildAISection {
    UIView *section = [[UIView alloc] init];
    [self.stack addArrangedSubview:section];
    self.aiSection = section;

    UIStackView *inner = [[UIStackView alloc] init];
    inner.axis = UILayoutConstraintAxisVertical;
    inner.spacing = [GLTheme spacingS];
    inner.translatesAutoresizingMaskIntoConstraints = NO;
    [section addSubview:inner];
    [NSLayoutConstraint activateConstraints:@[
        [inner.topAnchor constraintEqualToAnchor:section.topAnchor],
        [inner.leadingAnchor constraintEqualToAnchor:section.leadingAnchor],
        [inner.trailingAnchor constraintEqualToAnchor:section.trailingAnchor],
        [inner.bottomAnchor constraintEqualToAnchor:section.bottomAnchor],
    ]];

    [inner addArrangedSubview:[self sectionLabelWithTitle:@"PROMPT — resolved server-side against your quote library"]];

    UITextView *prompt = [[UITextView alloc] init];
    prompt.text = self.rule.prompt;
    prompt.font = [GLTheme bodyFont];
    prompt.textColor = [GLTheme textPrimaryColor];
    prompt.backgroundColor = [GLTheme surfaceColor];
    prompt.layer.cornerRadius = [GLTheme cornerRadius];
    prompt.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    [prompt.heightAnchor constraintEqualToConstant:80].active = YES;
    [inner addArrangedSubview:prompt];
    self.promptField = prompt;

    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = [GLTheme spacingS];
    row.alignment = UIStackViewAlignmentCenter;
    [inner addArrangedSubview:row];

    UIButton *rerun = [GLComponents primaryButtonWithTitle:@"Re-run"];
    [rerun addTarget:self action:@selector(rerunTapped) forControlEvents:UIControlEventTouchUpInside];
    [rerun.widthAnchor constraintEqualToConstant:100].active = YES;
    [row addArrangedSubview:rerun];
    self.rerunButton = rerun;

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.hidesWhenStopped = YES;
    [row addArrangedSubview:spinner];
    self.aiSpinner = spinner;

    UILabel *status = [GLComponents statusLabel];
    [inner addArrangedSubview:status];
    self.aiStatusLabel = status;
}

- (void)rerunTapped {
    NSString *prompt = self.promptField.text ?: @"";
    if (prompt.length == 0) {
        self.aiStatusLabel.text = @"Enter a prompt first.";
        return;
    }
    [self runAIResolveWithPrompt:prompt completion:nil];
}

/// Resolves `prompt` against every quote currently in the store. Updates
/// resolvedQuoteIds + the status label on success, leaves resolvedQuoteIds
/// UNCHANGED on failure (per the coordinator's directive: keep the rule's
/// previous quoteIds and show the error, no retry loop).
- (void)runAIResolveWithPrompt:(NSString *)prompt completion:(nullable void (^)(BOOL success))completion {
    self.rerunButton.enabled = NO;
    [self.aiSpinner startAnimating];
    self.aiStatusLabel.text = @"Resolving with AI — this can take 5–20s…";

    NSArray<GLQuote *> *allQuotes = [[QuotesStore sharedStore] allQuotes];
    __weak typeof(self) weakSelf = self;
    [QuotesAIFilterClient resolvePrompt:prompt
                           againstQuotes:allQuotes
                              completion:^(NSArray<NSString *> *_Nullable quoteIds, NSString *_Nullable errorMessage) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) return;
        [strongSelf.aiSpinner stopAnimating];
        strongSelf.rerunButton.enabled = YES;

        if (errorMessage != nil) {
            strongSelf.aiStatusLabel.text = [NSString stringWithFormat:@"AI resolve failed: %@ (kept previous %lu quote%@)",
                errorMessage, (unsigned long)strongSelf.resolvedQuoteIds.count, strongSelf.resolvedQuoteIds.count == 1 ? @"" : @"s"];
            if (completion != nil) completion(NO);
            return;
        }

        strongSelf.resolvedQuoteIds = [quoteIds mutableCopy];
        GLHapticSuccess();
        [strongSelf updateAIStatusLabel];
        if (completion != nil) completion(YES);
    }];
}

- (void)updateAIStatusLabel {
    if (self.resolvedQuoteIds.count == 0) {
        self.aiStatusLabel.text = @"No quotes matched yet.";
    } else {
        self.aiStatusLabel.text = [NSString stringWithFormat:@"%lu quote%@ matched.",
            (unsigned long)self.resolvedQuoteIds.count, self.resolvedQuoteIds.count == 1 ? @"" : @"s"];
    }
}

#pragma mark - Days

- (void)buildDaysRow {
    [self.stack addArrangedSubview:[self sectionLabelWithTitle:@"DAYS"]];
    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.spacing = [GLTheme spacingXXS];
    [self.stack addArrangedSubview:row];

    NSArray<NSString *> *labels = @[@"S", @"M", @"T", @"W", @"T", @"F", @"S"];
    for (NSInteger day = 1; day <= 7; day++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button setTitle:labels[(NSUInteger)day - 1] forState:UIControlStateNormal];
        button.titleLabel.font = [GLTheme captionFont];
        button.layer.cornerRadius = [GLTheme cornerRadius];
        button.tag = day;
        [button addTarget:self action:@selector(dayToggled:) forControlEvents:UIControlEventTouchUpInside];
        [button.heightAnchor constraintEqualToConstant:36].active = YES;
        [row addArrangedSubview:button];
        [self.dayButtons addObject:button];
    }
    [self refreshDayButtons];
}

- (void)dayToggled:(UIButton *)sender {
    NSNumber *day = @(sender.tag);
    if ([self.selectedDays containsObject:day]) {
        [self.selectedDays removeObject:day];
    } else {
        [self.selectedDays addObject:day];
    }
    [self refreshDayButtons];
}

- (void)refreshDayButtons {
    for (UIButton *button in self.dayButtons) {
        BOOL selected = [self.selectedDays containsObject:@(button.tag)];
        button.backgroundColor = selected ? [GLTheme accentColor] : [GLTheme surfaceColor];
        [button setTitleColor:selected ? UIColor.whiteColor : [GLTheme textPrimaryColor] forState:UIControlStateNormal];
    }
}

#pragma mark - Time window

- (NSDate *)dateForMinuteOfDay:(NSInteger)minuteOfDay {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *comps = [[NSDateComponents alloc] init];
    comps.year = 2020; comps.month = 1; comps.day = 1;
    comps.hour = (minuteOfDay % 1440) / 60;
    comps.minute = (minuteOfDay % 1440) % 60;
    return [calendar dateFromComponents:comps];
}

- (NSInteger)minuteOfDayForDate:(NSDate *)date {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *comps = [calendar components:(NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:date];
    return comps.hour * 60 + comps.minute;
}

- (void)buildTimeRows {
    [self.stack addArrangedSubview:[self sectionLabelWithTitle:@"TIME WINDOW (end before start wraps past midnight)"]];

    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.spacing = [GLTheme spacingS];
    [self.stack addArrangedSubview:row];

    UIStackView *startColumn = [[UIStackView alloc] init];
    startColumn.axis = UILayoutConstraintAxisVertical;
    [startColumn addArrangedSubview:[self sectionLabelWithTitle:@"Start"]];
    UIDatePicker *startPicker = [[UIDatePicker alloc] init];
    startPicker.datePickerMode = UIDatePickerModeTime;
    startPicker.minuteInterval = 5;
    startPicker.date = [self dateForMinuteOfDay:self.rule.startMinute];
    [startColumn addArrangedSubview:startPicker];
    [row addArrangedSubview:startColumn];
    self.startPicker = startPicker;

    UIStackView *endColumn = [[UIStackView alloc] init];
    endColumn.axis = UILayoutConstraintAxisVertical;
    [endColumn addArrangedSubview:[self sectionLabelWithTitle:@"End"]];
    UIDatePicker *endPicker = [[UIDatePicker alloc] init];
    endPicker.datePickerMode = UIDatePickerModeTime;
    endPicker.minuteInterval = 5;
    endPicker.date = [self dateForMinuteOfDay:self.rule.endMinute % 1440];
    [endColumn addArrangedSubview:endPicker];
    [row addArrangedSubview:endColumn];
    self.endPicker = endPicker;
}

#pragma mark - Rotate minutes

- (void)buildRotateRow {
    [self.stack addArrangedSubview:[self sectionLabelWithTitle:@"ROTATE EVERY"]];
    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = [GLTheme spacingS];
    row.alignment = UIStackViewAlignmentCenter;
    [self.stack addArrangedSubview:row];

    UILabel *value = [[UILabel alloc] init];
    value.font = [GLTheme bodyFont];
    value.textColor = [GLTheme textPrimaryColor];
    value.text = [NSString stringWithFormat:@"%ld minutes", (long)self.rule.rotateMinutes];
    [row addArrangedSubview:value];
    self.rotateValueLabel = value;

    UIStepper *stepper = [[UIStepper alloc] init];
    stepper.minimumValue = 5;
    stepper.maximumValue = 24 * 60;
    stepper.stepValue = 5;
    stepper.value = self.rule.rotateMinutes;
    [stepper addTarget:self action:@selector(rotateStepperChanged:) forControlEvents:UIControlEventValueChanged];
    [row addArrangedSubview:stepper];
    self.rotateStepper = stepper;
}

- (void)rotateStepperChanged:(UIStepper *)stepper {
    self.rotateValueLabel.text = [NSString stringWithFormat:@"%ld minutes", (long)(NSInteger)stepper.value];
}

#pragma mark - Save

- (void)buildSaveButton {
    UIButton *button = [GLComponents primaryButtonWithTitle:@"Save Rule"];
    [button addTarget:self action:@selector(saveTapped) forControlEvents:UIControlEventTouchUpInside];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:button];
    self.saveButton = button;

    CGFloat s = [GLTheme spacingM];
    [NSLayoutConstraint activateConstraints:@[
        [button.topAnchor constraintEqualToAnchor:self.scrollView.bottomAnchor constant:[GLTheme spacingXS]],
        [button.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:s],
        [button.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-s],
        [button.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-[GLTheme spacingXS]],
        [button.heightAnchor constraintEqualToConstant:[GLTheme controlHeight]],
    ]];
}

- (void)saveTapped {
    BOOL isAI = self.kindControl.selectedSegmentIndex == 1;
    NSString *prompt = self.promptField.text ?: @"";
    BOOL promptChanged = isAI && ![prompt isEqualToString:self.originalPrompt];

    if (isAI && promptChanged) {
        // Auto-resolve once on save with a new/changed prompt (per the
        // coordinator's directive), then persist with whatever quoteIds
        // that resolve produced (or the previous ones, on failure).
        __weak typeof(self) weakSelf = self;
        [self runAIResolveWithPrompt:prompt completion:^(BOOL success) {
            [weakSelf persistRule];
        }];
        return;
    }
    [self persistRule];
}

- (void)persistRule {
    BOOL isAI = self.kindControl.selectedSegmentIndex == 1;
    NSMutableArray<NSNumber *> *days = [[[self.selectedDays allObjects] sortedArrayUsingSelector:@selector(compare:)] mutableCopy];
    NSInteger startMinute = [self minuteOfDayForDate:self.startPicker.date];
    NSInteger endMinute = [self minuteOfDayForDate:self.endPicker.date];

    GLQuoteRule *savedRule = [[GLQuoteRule alloc] initWithId:self.rule.ruleId
                                                          name:self.nameField.text.length > 0 ? self.nameField.text : @"Untitled Rule"
                                                          kind:isAI ? GLQuoteRuleKindAI : GLQuoteRuleKindFilter
                                                       authors:[self.selectedAuthors allObjects]
                                                        genres:[self.selectedGenres allObjects]
                                                        prompt:self.promptField.text ?: @""
                                                      quoteIds:isAI ? [self.resolvedQuoteIds copy] : @[]
                                                          days:days
                                                   startMinute:startMinute
                                                     endMinute:endMinute
                                                 rotateMinutes:(NSInteger)self.rotateStepper.value];

    QuotesStore *store = [QuotesStore sharedStore];
    NSMutableArray<GLQuoteRule *> *rules = [[store rules] mutableCopy];
    NSUInteger existingIndex = [rules indexOfObjectPassingTest:^BOOL(GLQuoteRule *r, NSUInteger idx, BOOL *stop) {
        return [r.ruleId isEqualToString:savedRule.ruleId];
    }];
    if (existingIndex != NSNotFound) {
        rules[existingIndex] = savedRule;
    } else {
        [rules addObject:savedRule];
    }
    NSError *saveError = nil;
    BOOL saved = [store saveRules:rules error:&saveError];
    if (!saved) {
        [GLComponents showToastInView:self.view message:[NSString stringWithFormat:@"Not saved: %@", saveError.localizedDescription ?: @"keychain unavailable"]];
        return; // stay on the editor rather than pop and imply the rule was saved
    }

    [self.navigationController popViewControllerAnimated:YES];
}

@end
