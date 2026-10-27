#import "RecentRecordingsViewController.h"

#import "BakedConfig.h"
#import "GLEndpoints.h"
#import "GLTheme.h"

static NSString *const kCellIdentifier = @"RecentRecordingsCell";

#pragma mark - Notebook style

// "Notebook" look: newsprint-light paper in light mode (values from
// journal-review theme.css), the existing GLTheme dark palette in dark mode.
static UIColor *NBColor(UInt32 lightHex, UIColor *(^dark)(void)) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        if (t.userInterfaceStyle == UIUserInterfaceStyleDark) return dark();
        return [UIColor colorWithRed:((lightHex >> 16) & 0xFF) / 255.0
                               green:((lightHex >> 8) & 0xFF) / 255.0
                                blue:(lightHex & 0xFF) / 255.0
                               alpha:1];
    }];
}
static UIColor *NBPaper(void)  { return NBColor(0xfaf8f4, ^UIColor *{ return [GLTheme backgroundColor]; }); }
static UIColor *NBBorder(void) { return NBColor(0xe2ddd2, ^UIColor *{ return [[GLTheme textSecondaryColor] colorWithAlphaComponent:0.3]; }); }
static UIColor *NBText(void)   { return NBColor(0x211d16, ^UIColor *{ return [GLTheme textPrimaryColor]; }); }
static UIColor *NBDim(void)    { return NBColor(0x8d8676, ^UIColor *{ return [GLTheme textSecondaryColor]; }); }

// New York (system serif) at the given size/weight, optionally italic.
static UIFont *NBSerif(CGFloat size, UIFontWeight weight, BOOL italic) {
    UIFontDescriptor *d = [UIFont systemFontOfSize:size weight:weight].fontDescriptor;
    UIFontDescriptor *serif = [d fontDescriptorWithDesign:UIFontDescriptorSystemDesignSerif];
    if (serif) d = serif;
    if (italic) {
        UIFontDescriptor *it = [d fontDescriptorWithSymbolicTraits:d.symbolicTraits | UIFontDescriptorTraitItalic];
        if (it) d = it;
    }
    return [UIFont fontWithDescriptor:d size:size];
}

static UIView *NBHairline(void) {
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = NBBorder();
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [v.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale].active = YES;
    return v;
}

#pragma mark - Cell

// Flat notebook row: icon + serif transcript + small uppercase timestamp on
// paper, hairline separator at the bottom. Auto Layout (no fixed heights) so
// UITableViewAutomaticDimension and Dynamic Type keep working.
@interface GLRecentRecordingCell : UITableViewCell
@property(nonatomic, strong, readonly) UIImageView *kindImageView;
@property(nonatomic, strong, readonly) UILabel *transcriptLabel;
@property(nonatomic, strong, readonly) UILabel *timestampLabel;
// YES for "Transcribing…" / "(no words recognized)": muted italic.
@property(nonatomic, assign) BOOL placeholder;
@end

@implementation GLRecentRecordingCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(nullable NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = UIColor.clearColor;
        self.contentView.backgroundColor = UIColor.clearColor;

        _kindImageView = [[UIImageView alloc] init];
        _kindImageView.tintColor = NBDim();
        _kindImageView.contentMode = UIViewContentModeScaleAspectFit;
        _kindImageView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_kindImageView];

        _transcriptLabel = [[UILabel alloc] init];
        _transcriptLabel.numberOfLines = 0;
        _transcriptLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_transcriptLabel];

        _timestampLabel = [[UILabel alloc] init];
        _timestampLabel.font = [UIFont systemFontOfSize:12];
        _timestampLabel.textColor = NBDim();
        _timestampLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_timestampLabel];

        UIView *line = NBHairline();
        [self.contentView addSubview:line];

        [self applyPlaceholderStyle];

        [NSLayoutConstraint activateConstraints:@[
            [_kindImageView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:31],
            [_kindImageView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20],
            [_kindImageView.widthAnchor constraintEqualToConstant:18],
            [_kindImageView.heightAnchor constraintEqualToConstant:18],

            [_transcriptLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:26],
            [_transcriptLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:56],
            [_transcriptLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20],

            [_timestampLabel.topAnchor constraintEqualToAnchor:_transcriptLabel.bottomAnchor constant:10],
            [_timestampLabel.leadingAnchor constraintEqualToAnchor:_transcriptLabel.leadingAnchor],
            [_timestampLabel.trailingAnchor constraintEqualToAnchor:_transcriptLabel.trailingAnchor],
            [_timestampLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-26],

            [line.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [line.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [line.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        ]];
    }
    return self;
}

- (void)setPlaceholder:(BOOL)placeholder {
    _placeholder = placeholder;
    [self applyPlaceholderStyle];
}

- (void)applyPlaceholderStyle {
    UIFont *font = NBSerif(18, UIFontWeightRegular, _placeholder);
    _transcriptLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledFontForFont:font];
    _transcriptLabel.adjustsFontForContentSizeCategory = YES;
    _transcriptLabel.textColor = _placeholder ? NBDim() : NBText();
}

- (void)setTimestampText:(NSString *)text {
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc]
        initWithString:text.uppercaseString
            attributes:@{NSKernAttributeName : @0.72, NSFontAttributeName : _timestampLabel.font,
                         NSForegroundColorAttributeName : _timestampLabel.textColor}];
    _timestampLabel.attributedText = s;
}

@end

#pragma mark - RecentRecordingsViewController

@interface RecentRecordingsViewController ()

@property(nonatomic, strong) NSArray<NSDictionary *> *recordings;
@property(nonatomic, strong) NSString *loadErrorMessage;
@property(nonatomic, strong) NSDateFormatter *displayDateFormatter;
// Clean/Raw toggle state -- defaults to CLEANED, persisted across launches.
@property(nonatomic, assign) BOOL showCleanedTranscripts;
// In-content header's own copy of the toggle button -- see -buildHeaderRow.
// -updateTranscriptToggleButton keeps this AND navigationItem.rightBarButtonItem
// in sync together, since either one might be the one actually visible
// depending on how this screen was reached.
@property(nonatomic, strong) UIButton *headerTranscriptToggleButton;

@end

@implementation RecentRecordingsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStylePlain];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Recent";

    self.displayDateFormatter = [[NSDateFormatter alloc] init];
    self.displayDateFormatter.dateStyle = NSDateFormatterMediumStyle;
    self.displayDateFormatter.timeStyle = NSDateFormatterShortStyle;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    self.showCleanedTranscripts = [defaults objectForKey:GLJournalCleanedTranscriptsDefaultsName]
        ? [defaults boolForKey:GLJournalCleanedTranscriptsDefaultsName]
        : YES;

    // Costs nothing and is what draws whenever this screen is reached
    // through a navigation controller that DOES show its bar. See
    // -buildHeaderRow for the case (pushed onto GLMoreStackCoordinator's
    // hidden-bar "More" stack, which is how Journal's own Recent button
    // reaches this screen today) where nothing draws this at all.
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithImage:nil
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(transcriptToggleTapped)];
    self.navigationItem.rightBarButtonItem.accessibilityIdentifier = @"RecentRecordingsTranscriptToggle";

    self.tableView.backgroundColor = NBPaper();
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.accessibilityIdentifier = @"RecentRecordingsTable";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 110;

    [self buildHeaderRow];
    [self updateTranscriptToggleButton];

    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self
                             action:@selector(refreshTriggered)
                   forControlEvents:UIControlEventValueChanged];

    [self loadRecordings];
}

- (void)refreshTriggered {
    [self loadRecordings];
}

#pragma mark - In-content header

// This screen is reached (via AutoJournalViewController's Recent button)
// by pushing onto whatever `self.navigationController` Journal itself has —
// which, when Journal was opened as an overflow/"More" tab, is
// GLMoreStackCoordinator's shared More stack, and that stack's bar is
// hidden on every screen in it (see AutoJournalViewController's
// -buildHeaderRow doc comment for the full chain). That leaves both the
// back affordance UIKit would normally draw AND this screen's own
// Clean/Raw toggle (navigationItem.rightBarButtonItem above) with nowhere
// to draw. Set as `tableHeaderView` so it scrolls away with the rest of
// the grouped list, same as a real nav bar would sit fixed above it while
// still reading as native to this list.
- (void)buildHeaderRow {
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 64)];
    header.backgroundColor = NBPaper();

    UIButton *backButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [backButton setImage:[UIImage systemImageNamed:@"chevron.backward"] forState:UIControlStateNormal];
    backButton.tintColor = NBText();
    [backButton addTarget:self action:@selector(backTapped) forControlEvents:UIControlEventTouchUpInside];
    backButton.accessibilityIdentifier = @"RecentRecordingsBackButton";
    backButton.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:backButton];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"Recent";
    titleLabel.font = NBSerif(24, UIFontWeightSemibold, NO);
    titleLabel.textColor = NBText();
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:titleLabel];

    self.headerTranscriptToggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.headerTranscriptToggleButton.tintColor = NBText();
    [self.headerTranscriptToggleButton addTarget:self
                                           action:@selector(transcriptToggleTapped)
                                 forControlEvents:UIControlEventTouchUpInside];
    self.headerTranscriptToggleButton.accessibilityIdentifier = @"RecentRecordingsHeaderTranscriptToggle";
    self.headerTranscriptToggleButton.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:self.headerTranscriptToggleButton];

    UIView *headerLine = NBHairline();
    [header addSubview:headerLine];

    [NSLayoutConstraint activateConstraints:@[
        [headerLine.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [headerLine.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [headerLine.bottomAnchor constraintEqualToAnchor:header.bottomAnchor],

        [backButton.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:12],
        [backButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [titleLabel.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [titleLabel.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [self.headerTranscriptToggleButton.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-12],
        [self.headerTranscriptToggleButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
    ]];

    self.tableView.tableHeaderView = header;
}

- (void)backTapped {
    [self.navigationController popViewControllerAnimated:YES];
}

#pragma mark - Clean/Raw toggle

- (void)updateTranscriptToggleButton {
    NSString *symbolName = self.showCleanedTranscripts ? @"wand.and.stars" : @"text.alignleft";
    NSString *accessibilityLabel =
        self.showCleanedTranscripts ? @"Showing cleaned transcripts" : @"Showing raw transcripts";

    self.navigationItem.rightBarButtonItem.image = [UIImage systemImageNamed:symbolName];
    self.navigationItem.rightBarButtonItem.accessibilityLabel = accessibilityLabel;

    [self.headerTranscriptToggleButton setImage:[UIImage systemImageNamed:symbolName]
                                        forState:UIControlStateNormal];
    self.headerTranscriptToggleButton.accessibilityLabel = accessibilityLabel;
}

- (void)transcriptToggleTapped {
    self.showCleanedTranscripts = !self.showCleanedTranscripts;
    [[NSUserDefaults standardUserDefaults] setBool:self.showCleanedTranscripts
                                             forKey:GLJournalCleanedTranscriptsDefaultsName];
    [self updateTranscriptToggleButton];
    [self.tableView reloadData];
}

#pragma mark - Loading

- (void)loadRecordings {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        GLEndpointURL(@"/journal/recordings?limit=20")];
    request.HTTPMethod = @"GET";
    [request setValue:[NSString stringWithFormat:@"Bearer %@", GL_BAKED_TOKEN]
        forHTTPHeaderField:@"Authorization"];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf handleResponse:response data:data error:error];
        });
    }];
    [task resume];
}

- (void)handleResponse:(NSURLResponse *)response data:(NSData *)data error:(NSError *)error {
    [self.refreshControl endRefreshing];

    if (error) {
        self.recordings = nil;
        self.loadErrorMessage = error.localizedDescription;
        [self.tableView reloadData];
        return;
    }

    NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
    if (status < 200 || status > 299) {
        self.recordings = nil;
        self.loadErrorMessage = [NSString stringWithFormat:@"HTTP %ld", (long)status];
        [self.tableView reloadData];
        return;
    }

    NSError *jsonError = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (jsonError || ![json isKindOfClass:[NSDictionary class]]) {
        self.recordings = nil;
        self.loadErrorMessage = @"Couldn't read the server's response.";
        [self.tableView reloadData];
        return;
    }

    self.loadErrorMessage = nil;
    self.recordings = json[@"recordings"];
    [self.tableView reloadData];
}

#pragma mark - Empty / error state

- (void)updateBackgroundView {
    NSString *message = nil;
    if (self.loadErrorMessage) {
        message = [NSString stringWithFormat:@"Couldn't load recordings: %@", self.loadErrorMessage];
    } else if (self.recordings.count == 0) {
        message = @"No recordings yet.";
    }

    if (!message) {
        self.tableView.backgroundView = nil;
        return;
    }

    UILabel *label = [[UILabel alloc] init];
    label.text = message;
    label.font = NBSerif(18, UIFontWeightRegular, YES);
    label.textColor = NBDim();
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.accessibilityIdentifier = @"RecentRecordingsEmptyLabel";
    label.frame = CGRectInset(self.tableView.bounds, 32, 0);
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.backgroundView = label;
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    [self updateBackgroundView];
    return self.recordings.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    GLRecentRecordingCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellIdentifier];
    if (!cell) {
        cell = [[GLRecentRecordingCell alloc] initWithStyle:UITableViewCellStyleDefault
                                             reuseIdentifier:kCellIdentifier];
    }
    NSDictionary *recording = self.recordings[indexPath.row];

    cell.transcriptLabel.text = [self transcriptTextForRecording:recording];
    [cell setTimestampText:[self timestampTextForRecording:recording]];
    id rawTranscript = recording[@"transcript"];
    cell.placeholder = ![rawTranscript isKindOfClass:[NSString class]] || [(NSString *)rawTranscript length] == 0;

    BOOL isVoice = [recording[@"kind"] isEqualToString:@"voice"];
    cell.kindImageView.image = [UIImage systemImageNamed:isVoice ? @"mic.fill" : @"text.alignleft"];
    cell.accessibilityIdentifier =
        [NSString stringWithFormat:@"RecentRecordingsCell_%ld", (long)indexPath.row];
    return cell;
}

#pragma mark - Cell text

- (NSString *)transcriptTextForRecording:(NSDictionary *)recording {
    id transcript = recording[@"transcript"];
    if (transcript == nil || transcript == [NSNull null]) return @"Transcribing…";
    if (![transcript isKindOfClass:[NSString class]]) return @"Transcribing…";
    if ([(NSString *)transcript length] == 0) return @"(no words recognized)";

    if (!self.showCleanedTranscripts) return transcript;

    // transcriptClean is a String when cleanup succeeded, null when it
    // failed -- a failed cleanup must fall back to the raw transcript, not
    // blank the row.
    id clean = recording[@"transcriptClean"];
    return [clean isKindOfClass:[NSString class]] ? clean : transcript;
}

- (NSString *)timestampTextForRecording:(NSDictionary *)recording {
    NSString *savedAt = recording[@"savedAt"];
    if (![savedAt isKindOfClass:[NSString class]]) return @"";

    static NSISO8601DateFormatter *isoFormatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        isoFormatter = [[NSISO8601DateFormatter alloc] init];
        isoFormatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                                      NSISO8601DateFormatWithFractionalSeconds;
    });
    NSDate *date = [isoFormatter dateFromString:savedAt];
    if (!date) return savedAt;
    return [self.displayDateFormatter stringFromDate:date];
}

@end
