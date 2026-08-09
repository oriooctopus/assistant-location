#import "RecentRecordingsViewController.h"

#import "BakedConfig.h"
#import "GLEndpoints.h"

static NSString *const kCellIdentifier = @"RecentRecordingsCell";

@interface RecentRecordingsViewController ()

@property(nonatomic, strong) NSArray<NSDictionary *> *recordings;
@property(nonatomic, strong) NSString *loadErrorMessage;
@property(nonatomic, strong) NSDateFormatter *displayDateFormatter;

@end

@implementation RecentRecordingsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Recent";

    self.displayDateFormatter = [[NSDateFormatter alloc] init];
    self.displayDateFormatter.dateStyle = NSDateFormatterMediumStyle;
    self.displayDateFormatter.timeStyle = NSDateFormatterShortStyle;

    self.tableView.accessibilityIdentifier = @"RecentRecordingsTable";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 60;

    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self
                             action:@selector(refreshTriggered)
                   forControlEvents:UIControlEventValueChanged];

    [self loadRecordings];
}

- (void)refreshTriggered {
    [self loadRecordings];
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
    label.font = [UIFont systemFontOfSize:15];
    label.textColor = UIColor.secondaryLabelColor;
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
    // Subtitle style, not registerClass:, because the detail (timestamp) line
    // only exists on the Subtitle/Value1/Value2 cell styles — the default
    // style UITableViewCell vends from a plain class registration has a nil
    // detailTextLabel.
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                       reuseIdentifier:kCellIdentifier];
    }
    NSDictionary *recording = self.recordings[indexPath.row];

    cell.textLabel.text = [self transcriptTextForRecording:recording];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.text = [self timestampTextForRecording:recording];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;

    BOOL isVoice = [recording[@"kind"] isEqualToString:@"voice"];
    cell.imageView.image = [UIImage systemImageNamed:isVoice ? @"mic.fill" : @"text.alignleft"];
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
    return transcript;
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
