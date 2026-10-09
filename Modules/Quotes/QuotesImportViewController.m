#import "QuotesImportViewController.h"

#import "QuotesTheme.h"
#import "Overland-Swift.h" // GLQuotesWidgetReload (Modules/ files are compiled into JournalControl too, so this stays out of QuotesStore.m itself -- see App/QuotesWidgetReload.swift)
#import "QuotesStore.h"
#import "QuotesModels.h"
#import "QuotesImportParser.h"

static NSString *const kImportCellIdentifier = @"ImportPreviewCell";

/// One row in the preview table: a parsed quote plus whether it duplicates
/// something already in the store or earlier in this same batch.
@interface QuotesImportPreviewRow : NSObject
@property(nonatomic, copy) NSString *text;
@property(nonatomic, copy) NSString *author;
@property(nonatomic, assign) BOOL isDuplicate;
@end
@implementation QuotesImportPreviewRow
@end

@interface QuotesImportViewController () <UITableViewDataSource, UITableViewDelegate, UITextViewDelegate>
@property(nonatomic, strong) UITextView *pasteBox;
@property(nonatomic, strong) UILabel *pasteBoxPlaceholder;
@property(nonatomic, strong) UIButton *parseButton;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UITableView *previewTable;
@property(nonatomic, strong) UIButton *saveButton;
@property(nonatomic, strong) NSLayoutConstraint *pasteBoxHeightConstraint;

@property(nonatomic, copy) NSArray<QuotesImportPreviewRow *> *previewRows;
@end

@implementation QuotesImportViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [QuotesTheme styleScreenView:self.view];
    [QuotesTheme installBackLinkInViewController:self];
    self.previewRows = @[];

    [self buildPasteBox];
    [self buildParseButton];
    [self buildStatusLabel];
    [self buildPreviewTable];
    [self buildSaveButton];
    [self updateSaveButtonState];
}

#pragma mark - Layout

- (void)buildPasteBox {
    UITextView *textView = [[UITextView alloc] init];
    textView.font = [QuotesTheme bodyFont];
    textView.textColor = [QuotesTheme textPrimaryColor];
    [QuotesTheme styleField:textView];

    textView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    textView.delegate = self;
    textView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:textView];
    self.pasteBox = textView;

    UILabel *placeholder = [[UILabel alloc] init];
    placeholder.text = @"Paste quotes here, one per line or in blank-line-separated blocks. \"Text\" — Author, text - Author, text ~ Author, or text,author all work.";
    placeholder.font = [QuotesTheme bodyFont];
    placeholder.textColor = [QuotesTheme textSecondaryColor];
    placeholder.numberOfLines = 0;
    placeholder.translatesAutoresizingMaskIntoConstraints = NO;
    placeholder.userInteractionEnabled = NO;
    [textView addSubview:placeholder];
    self.pasteBoxPlaceholder = placeholder;

    CGFloat s = [QuotesTheme spacingM];
    self.pasteBoxHeightConstraint = [textView.heightAnchor constraintEqualToConstant:140];
    [NSLayoutConstraint activateConstraints:@[
        [textView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:s],
        [textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:s],
        [textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-s],
        self.pasteBoxHeightConstraint,

        [placeholder.topAnchor constraintEqualToAnchor:textView.topAnchor constant:8],
        [placeholder.leadingAnchor constraintEqualToAnchor:textView.leadingAnchor constant:12],
        [placeholder.trailingAnchor constraintEqualToAnchor:textView.trailingAnchor constant:-12],
    ]];
}

- (void)buildParseButton {
    UIButton *button = [QuotesTheme primaryButtonWithTitle:@"Parse"];
    [button addTarget:self action:@selector(parseTapped) forControlEvents:UIControlEventTouchUpInside];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:button];
    self.parseButton = button;

    CGFloat s = [QuotesTheme spacingM];
    [NSLayoutConstraint activateConstraints:@[
        [button.topAnchor constraintEqualToAnchor:self.pasteBox.bottomAnchor constant:[QuotesTheme spacingXS]],
        [button.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:s],
        [button.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-s],
        [button.heightAnchor constraintEqualToConstant:[QuotesTheme controlHeight]],
    ]];
}

- (void)buildStatusLabel {
    UILabel *label = [QuotesTheme statusLabel];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:label];
    self.statusLabel = label;

    CGFloat s = [QuotesTheme spacingM];
    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:self.parseButton.bottomAnchor constant:[QuotesTheme spacingXXS]],
        [label.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:s],
        [label.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-s],
    ]];
}

- (void)buildPreviewTable {
    UITableView *table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    table.dataSource = self;
    table.delegate = self;
    table.backgroundColor = [QuotesTheme paper];
    table.separatorColor = [QuotesTheme hairline];
    table.separatorInset = UIEdgeInsetsZero;
    table.rowHeight = UITableViewAutomaticDimension;
    table.estimatedRowHeight = 64;
    table.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:table];
    self.previewTable = table;

    [NSLayoutConstraint activateConstraints:@[
        [table.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:[QuotesTheme spacingXS]],
        [table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
}

- (void)buildSaveButton {
    UIButton *button = [QuotesTheme primaryButtonWithTitle:@"Save Quotes"];
    [button addTarget:self action:@selector(saveTapped) forControlEvents:UIControlEventTouchUpInside];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:button];
    self.saveButton = button;

    CGFloat s = [QuotesTheme spacingM];
    [NSLayoutConstraint activateConstraints:@[
        [button.topAnchor constraintEqualToAnchor:self.previewTable.bottomAnchor constant:[QuotesTheme spacingXS]],
        [button.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:s],
        [button.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-s],
        [button.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-[QuotesTheme spacingXS]],
        [button.heightAnchor constraintEqualToConstant:[QuotesTheme controlHeight]],
    ]];
}

#pragma mark - UITextViewDelegate

- (void)textViewDidChange:(UITextView *)textView {
    self.pasteBoxPlaceholder.hidden = textView.text.length > 0;
}

#pragma mark - Parse

- (void)parseTapped {
    [self.pasteBox resignFirstResponder];
    NSArray<QuotesParsedQuote *> *parsed = [QuotesImportParser parseText:self.pasteBox.text];

    NSArray<GLQuote *> *existing = [[QuotesStore sharedStore] allQuotes];
    NSMutableSet<NSString *> *existingNormalized = [NSMutableSet set];
    for (GLQuote *quote in existing) {
        [existingNormalized addObject:[QuotesImportParser normalizeTextForDedupe:quote.text]];
    }

    NSMutableSet<NSString *> *seenInBatch = [NSMutableSet set];
    NSMutableArray<QuotesImportPreviewRow *> *rows = [NSMutableArray arrayWithCapacity:parsed.count];
    for (QuotesParsedQuote *p in parsed) {
        NSString *normalized = [QuotesImportParser normalizeTextForDedupe:p.text];
        BOOL isDuplicate = [existingNormalized containsObject:normalized] || [seenInBatch containsObject:normalized];
        [seenInBatch addObject:normalized];

        QuotesImportPreviewRow *row = [[QuotesImportPreviewRow alloc] init];
        row.text = p.text;
        row.author = p.author;
        row.isDuplicate = isDuplicate;
        [rows addObject:row];
    }
    self.previewRows = rows;
    [self.previewTable reloadData];

    NSUInteger newCount = 0;
    for (QuotesImportPreviewRow *row in rows) if (!row.isDuplicate) newCount++;
    if (rows.count == 0) {
        self.statusLabel.text = @"Nothing parsed — paste some quotes above and tap Parse.";
    } else {
        self.statusLabel.text = [NSString stringWithFormat:@"Parsed %lu — %lu new, %lu already in your library",
            (unsigned long)rows.count, (unsigned long)newCount, (unsigned long)(rows.count - newCount)];
    }
    [self updateSaveButtonState];
}

- (void)updateSaveButtonState {
    NSUInteger newCount = 0;
    for (QuotesImportPreviewRow *row in self.previewRows) if (!row.isDuplicate) newCount++;
    self.saveButton.enabled = newCount > 0;
    self.saveButton.alpha = newCount > 0 ? 1.0 : 0.5;
    [self.saveButton setTitle:newCount > 0 ? [NSString stringWithFormat:@"Save %lu Quote%@", (unsigned long)newCount, newCount == 1 ? @"" : @"s"]
                                            : @"Save Quotes"
                      forState:UIControlStateNormal];
}

#pragma mark - Save

- (void)saveTapped {
    NSMutableArray<GLQuote *> *toSave = [NSMutableArray array];
    for (QuotesImportPreviewRow *row in self.previewRows) {
        if (row.isDuplicate) continue;
        NSString *quoteId = [@"imported-" stringByAppendingString:[NSUUID UUID].UUIDString];
        GLQuote *quote = [[GLQuote alloc] initWithId:quoteId
                                                  text:row.text
                                                author:row.author
                                                genres:@[]
                                                source:GLQuoteSourceImported];
        [toSave addObject:quote];
    }
    if (toSave.count == 0) return;

    NSError *saveError = nil;
    BOOL saved = [[QuotesStore sharedStore] addImportedQuotes:toSave error:&saveError];
    if (saved) [GLQuotesWidgetReload reloadAllTimelines]; // newly-imported quotes can now show up in the widget's pool
    if (!saved) {
        self.statusLabel.text = [NSString stringWithFormat:@"Not saved: %@", saveError.localizedDescription ?: @"keychain unavailable"];
        [QuotesTheme showToastInView:self.view message:self.statusLabel.text];
        return;
    }

    self.pasteBox.text = @"";
    self.pasteBoxPlaceholder.hidden = NO;
    self.previewRows = @[];
    [self.previewTable reloadData];
    self.statusLabel.text = [NSString stringWithFormat:@"Saved %lu quote%@.", (unsigned long)toSave.count, toSave.count == 1 ? @"" : @"s"];
    [self updateSaveButtonState];
    [QuotesTheme showToastInView:self.view message:[NSString stringWithFormat:@"Saved %lu quote%@", (unsigned long)toSave.count, toSave.count == 1 ? @"" : @"s"]];

    if (self.onQuotesImported != nil) self.onQuotesImported();
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.previewRows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kImportCellIdentifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kImportCellIdentifier];
    }
    QuotesImportPreviewRow *row = self.previewRows[(NSUInteger)indexPath.row];

    cell.backgroundColor = [QuotesTheme paper];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.font = [QuotesTheme bodyFont];
    cell.textLabel.textColor = row.isDuplicate ? [QuotesTheme textSecondaryColor] : [QuotesTheme textPrimaryColor];
    cell.textLabel.text = row.text;

    cell.detailTextLabel.font = [QuotesTheme captionFont];
    cell.detailTextLabel.textColor = [QuotesTheme textSecondaryColor];
    cell.detailTextLabel.text = row.isDuplicate
        ? [NSString stringWithFormat:@"%@ · already in your library", row.author]
        : row.author;

    return cell;
}

@end
