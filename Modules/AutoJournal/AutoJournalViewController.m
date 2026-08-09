#import "AutoJournalViewController.h"

#import <AVFoundation/AVFoundation.h>

#import "BakedConfig.h"
#import "GLEndpoints.h"
#import "GLDropUploader.h"
#import "RecentRecordingsViewController.h"

static NSString *const kJournalStartCaptureNotification = @"GLJournalStartCapture";
static NSString *const kJournalStartTextEntryNotification = @"GLJournalStartTextEntry";
static NSString *const kNoteFieldPlaceholder = @"Type a short entry";

typedef NS_ENUM(NSInteger, AutoJournalRecordingState) {
    AutoJournalRecordingStateIdle,
    AutoJournalRecordingStateRecording,
    AutoJournalRecordingStatePaused,
};

@interface AutoJournalViewController () <AVAudioRecorderDelegate, UITextFieldDelegate, UITextViewDelegate>

@property(nonatomic, strong) UISegmentedControl *modeControl;
@property(nonatomic, strong) UITextField *titleField;
@property(nonatomic, strong) UILabel *draftBannerLabel;

@property(nonatomic, strong) UITextView *noteTextView;
@property(nonatomic, strong) UIButton *saveNoteButton;

@property(nonatomic, strong) UIButton *recordButton;
@property(nonatomic, strong) UILabel *elapsedLabel;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIButton *retryButton;
@property(nonatomic, strong) UIButton *cancelButton;
@property(nonatomic, strong) UIButton *saveButton;

@property(nonatomic, strong) NSArray<UIView *> *voiceModeViews;
@property(nonatomic, strong) NSArray<UIView *> *textModeViews;

@property(nonatomic, strong) AVAudioRecorder *recorder;
@property(nonatomic, strong) NSTimer *elapsedTimer;
@property(nonatomic, assign) NSTimeInterval currentSegmentStartTime;
@property(nonatomic, assign) NSTimeInterval accumulatedElapsed;
@property(nonatomic, strong) NSMutableArray<NSString *> *segmentPaths;
@property(nonatomic, strong) NSDate *draftStartDate;
@property(nonatomic, assign) BOOL restoredFromDraft;
@property(nonatomic, assign) BOOL discardingSegment;
@property(nonatomic, assign) AutoJournalRecordingState recordingState;

@property(nonatomic, copy) NSString *pendingRetryPath;
@property(nonatomic, assign) BOOL pendingRetryIsVoice;
@property(nonatomic, copy) NSString *pendingRetryTitleSlug;
@property(nonatomic, assign) BOOL autoStartOnPermissionGranted;

@end

@implementation AutoJournalViewController

- (instancetype)init {
    self = [super init];
    if (self) {
        // Registered here, not in -viewDidLoad: a background tab's view may
        // not have loaded yet when the app cold-launches from the lock-screen
        // Control, but every module's +makeViewController (and therefore this
        // initializer) runs at launch before the intent's notification can
        // fire, whether that's a cold launch or a foreground handoff.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(handleStartCaptureNotification)
                                                      name:kJournalStartCaptureNotification
                                                    object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(handleStartTextEntryNotification)
                                                      name:kJournalStartTextEntryNotification
                                                    object:nil];
        self.segmentPaths = [NSMutableArray array];
        self.recordingState = AutoJournalRecordingStateIdle;
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Layout

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = @"Journal";

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"clock.arrow.circlepath"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(recentTapped)];

    [self buildModeToggleAndTitleField];
    [self buildRecorderUI];
    [self buildTextEntryUI];

    [self modeChanged:nil];
    [self updateUIForState];
    [self loadDraftIfPresent];
}

- (void)recentTapped {
    [self.navigationController pushViewController:[[RecentRecordingsViewController alloc] init]
                                          animated:YES];
}

- (void)buildModeToggleAndTitleField {
    self.modeControl = [[UISegmentedControl alloc] initWithItems:@[@"Voice", @"Text"]];
    self.modeControl.selectedSegmentIndex = 0;
    [self.modeControl addTarget:self
                          action:@selector(modeChanged:)
                forControlEvents:UIControlEventValueChanged];
    self.modeControl.accessibilityIdentifier = @"AutoJournalModeToggle";
    self.modeControl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.modeControl];

    self.titleField = [[UITextField alloc] init];
    self.titleField.placeholder = @"Title (optional)";
    self.titleField.borderStyle = UITextBorderStyleRoundedRect;
    self.titleField.returnKeyType = UIReturnKeyDone;
    self.titleField.delegate = self;
    self.titleField.accessibilityIdentifier = @"AutoJournalTitleField";
    self.titleField.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.titleField];

    self.draftBannerLabel = [[UILabel alloc] init];
    self.draftBannerLabel.font = [UIFont systemFontOfSize:13];
    self.draftBannerLabel.textColor = UIColor.systemOrangeColor;
    self.draftBannerLabel.textAlignment = NSTextAlignmentCenter;
    self.draftBannerLabel.numberOfLines = 0;
    self.draftBannerLabel.hidden = YES;
    self.draftBannerLabel.accessibilityIdentifier = @"AutoJournalDraftBanner";
    self.draftBannerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.draftBannerLabel];

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.modeControl.topAnchor constraintEqualToAnchor:guide.topAnchor constant:16],
        [self.modeControl.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:20],
        [self.modeControl.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-20],

        [self.titleField.topAnchor constraintEqualToAnchor:self.modeControl.bottomAnchor constant:16],
        [self.titleField.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:20],
        [self.titleField.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-20],

        [self.draftBannerLabel.topAnchor constraintEqualToAnchor:self.titleField.bottomAnchor constant:10],
        [self.draftBannerLabel.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:20],
        [self.draftBannerLabel.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-20],
    ]];
}

- (void)buildRecorderUI {
    self.recordButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.recordButton setImage:[UIImage systemImageNamed:@"mic.circle.fill"]
                        forState:UIControlStateNormal];
    self.recordButton.tintColor = UIColor.systemRedColor;
    self.recordButton.contentVerticalAlignment = UIControlContentVerticalAlignmentFill;
    self.recordButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentFill;
    self.recordButton.imageView.contentMode = UIViewContentModeScaleAspectFit;
    [self.recordButton addTarget:self
                           action:@selector(recordButtonTapped)
                 forControlEvents:UIControlEventTouchUpInside];
    self.recordButton.accessibilityIdentifier = @"AutoJournalRecordButton";
    self.recordButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.recordButton];

    self.elapsedLabel = [[UILabel alloc] init];
    self.elapsedLabel.text = @"00:00";
    self.elapsedLabel.font = [UIFont monospacedDigitSystemFontOfSize:28 weight:UIFontWeightRegular];
    self.elapsedLabel.textAlignment = NSTextAlignmentCenter;
    self.elapsedLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.elapsedLabel];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.text = @"Tap to record";
    self.statusLabel.font = [UIFont systemFontOfSize:15];
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    // Lets XCUITest assert on recording state (text goes "Tap to record" ->
    // "Recording…" once startRecording actually runs) without fragile
    // text-matching on the accessibility tree.
    self.statusLabel.accessibilityIdentifier = @"AutoJournalStatusLabel";
    [self.view addSubview:self.statusLabel];

    self.retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.retryButton setTitle:@"Retry upload" forState:UIControlStateNormal];
    self.retryButton.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [self.retryButton addTarget:self
                          action:@selector(retryTapped)
                forControlEvents:UIControlEventTouchUpInside];
    self.retryButton.hidden = YES;
    self.retryButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.retryButton];

    self.cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.cancelButton setTitle:@"Cancel" forState:UIControlStateNormal];
    self.cancelButton.titleLabel.font = [UIFont systemFontOfSize:17];
    self.cancelButton.tintColor = UIColor.systemRedColor;
    [self.cancelButton addTarget:self
                           action:@selector(cancelButtonTapped)
                 forControlEvents:UIControlEventTouchUpInside];
    self.cancelButton.hidden = YES;
    self.cancelButton.accessibilityIdentifier = @"AutoJournalCancelButton";
    self.cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.cancelButton];

    self.saveButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.saveButton setTitle:@"Save" forState:UIControlStateNormal];
    self.saveButton.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [self.saveButton addTarget:self
                         action:@selector(saveButtonTapped)
               forControlEvents:UIControlEventTouchUpInside];
    self.saveButton.hidden = YES;
    self.saveButton.accessibilityIdentifier = @"AutoJournalSaveButton";
    self.saveButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.saveButton];

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.recordButton.centerXAnchor constraintEqualToAnchor:guide.centerXAnchor],
        [self.recordButton.centerYAnchor constraintEqualToAnchor:guide.centerYAnchor],
        [self.recordButton.widthAnchor constraintEqualToConstant:120],
        [self.recordButton.heightAnchor constraintEqualToConstant:120],

        [self.elapsedLabel.topAnchor constraintEqualToAnchor:self.recordButton.bottomAnchor
                                                      constant:20],
        [self.elapsedLabel.centerXAnchor constraintEqualToAnchor:guide.centerXAnchor],

        [self.statusLabel.topAnchor constraintEqualToAnchor:self.elapsedLabel.bottomAnchor
                                                     constant:12],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:32],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-32],

        [self.retryButton.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor
                                                     constant:16],
        [self.retryButton.centerXAnchor constraintEqualToAnchor:guide.centerXAnchor],

        [self.cancelButton.topAnchor constraintEqualToAnchor:self.retryButton.bottomAnchor
                                                      constant:16],
        [self.cancelButton.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:40],
        [self.cancelButton.widthAnchor constraintEqualToConstant:100],

        [self.saveButton.topAnchor constraintEqualToAnchor:self.retryButton.bottomAnchor constant:16],
        [self.saveButton.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-40],
        [self.saveButton.widthAnchor constraintEqualToConstant:100],
    ]];

    self.voiceModeViews = @[
        self.recordButton, self.elapsedLabel, self.statusLabel,
        self.retryButton, self.cancelButton, self.saveButton
    ];
}

- (void)buildTextEntryUI {
    self.noteTextView = [[UITextView alloc] init];
    self.noteTextView.font = [UIFont systemFontOfSize:17];
    self.noteTextView.layer.borderColor = UIColor.separatorColor.CGColor;
    self.noteTextView.layer.borderWidth = 1;
    self.noteTextView.layer.cornerRadius = 8;
    self.noteTextView.text = kNoteFieldPlaceholder;
    self.noteTextView.textColor = UIColor.placeholderTextColor;
    self.noteTextView.delegate = self;
    self.noteTextView.accessibilityIdentifier = @"AutoJournalNoteTextView";
    self.noteTextView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.noteTextView];

    self.saveNoteButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.saveNoteButton setTitle:@"Save" forState:UIControlStateNormal];
    self.saveNoteButton.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [self.saveNoteButton addTarget:self
                             action:@selector(saveNoteTapped)
                   forControlEvents:UIControlEventTouchUpInside];
    self.saveNoteButton.accessibilityIdentifier = @"AutoJournalTextSaveButton";
    self.saveNoteButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.saveNoteButton];

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.noteTextView.topAnchor constraintEqualToAnchor:self.draftBannerLabel.bottomAnchor
                                                      constant:16],
        [self.noteTextView.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:20],
        [self.noteTextView.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-20],
        [self.noteTextView.bottomAnchor constraintEqualToAnchor:self.saveNoteButton.topAnchor
                                                          constant:-16],

        [self.saveNoteButton.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-24],
        [self.saveNoteButton.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-20],
    ]];

    self.textModeViews = @[self.noteTextView, self.saveNoteButton];
}

#pragma mark - Mode toggle

- (void)modeChanged:(UISegmentedControl *)sender {
    BOOL isVoice = self.modeControl.selectedSegmentIndex == 0;
    for (UIView *view in self.voiceModeViews) view.hidden = !isVoice;
    for (UIView *view in self.textModeViews) view.hidden = isVoice;
    self.draftBannerLabel.hidden = !(isVoice && self.restoredFromDraft);
    if (isVoice) {
        // Re-derives cancel/save visibility and the record button's icon
        // from the current recording state, which modeChanged doesn't know
        // about on its own.
        [self updateUIForState];
    }
}

#pragma mark - Lock-screen Control handoff

- (void)handleStartCaptureNotification {
    [self selectJournalTab];
    self.modeControl.selectedSegmentIndex = 0;
    [self modeChanged:nil];

    if (self.recordingState != AutoJournalRecordingStateIdle) return;
    [self beginRecordingFlow];
}

- (void)handleStartTextEntryNotification {
    [self selectJournalTab];
    self.modeControl.selectedSegmentIndex = 1;
    [self modeChanged:nil];
    [self.noteTextView becomeFirstResponder];
}

- (void)selectJournalTab {
    UITabBarController *tabs = self.tabBarController;
    if (!tabs) return;
    // The tab's own entry in tabs.viewControllers is now the UINavigationController
    // AutoJournalModule wraps this VC in (see AutoJournalModule.m), not self.
    NSUInteger index = [tabs.viewControllers indexOfObject:self.navigationController];
    if (index != NSNotFound) {
        tabs.selectedIndex = index;
    }
}

#pragma mark - Recording state / UI

- (void)updateUIForState {
    self.saveButton.enabled = YES;
    switch (self.recordingState) {
        case AutoJournalRecordingStateIdle:
            [self.recordButton setImage:[UIImage systemImageNamed:@"mic.circle.fill"]
                                forState:UIControlStateNormal];
            self.cancelButton.hidden = YES;
            self.saveButton.hidden = YES;
            break;
        case AutoJournalRecordingStateRecording:
            [self.recordButton setImage:[UIImage systemImageNamed:@"pause.circle.fill"]
                                forState:UIControlStateNormal];
            self.cancelButton.hidden = NO;
            self.saveButton.hidden = NO;
            break;
        case AutoJournalRecordingStatePaused:
            [self.recordButton setImage:[UIImage systemImageNamed:@"mic.circle.fill"]
                                forState:UIControlStateNormal];
            self.cancelButton.hidden = NO;
            self.saveButton.hidden = NO;
            break;
    }
    if (self.modeControl.selectedSegmentIndex == 0) {
        self.draftBannerLabel.hidden = !self.restoredFromDraft;
    }
}

#pragma mark - Recording

- (void)recordButtonTapped {
    switch (self.recordingState) {
        case AutoJournalRecordingStateIdle:
        case AutoJournalRecordingStatePaused:
            // Paused -> Idle-permission-path starts a brand new segment,
            // which is exactly "resume".
            [self beginRecordingFlow];
            break;
        case AutoJournalRecordingStateRecording:
            [self pauseRecording];
            break;
    }
}

- (void)beginRecordingFlow {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (session.recordPermission == AVAudioSessionRecordPermissionGranted) {
        [self startRecording];
        return;
    }
    self.autoStartOnPermissionGranted = YES;
    [session requestRecordPermission:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!granted) {
                self.statusLabel.text = @"Microphone access denied. Enable it in Settings to record.";
                self.autoStartOnPermissionGranted = NO;
                return;
            }
            if (self.autoStartOnPermissionGranted) {
                self.autoStartOnPermissionGranted = NO;
                [self startRecording];
            }
        });
    }];
}

- (void)startRecording {
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayAndRecord error:&error];
    if (!error) [session setActive:YES error:&error];
    if (error) {
        self.statusLabel.text = [NSString stringWithFormat:@"Couldn't start the audio session: %@",
                                                             error.localizedDescription];
        return;
    }

    // Segments live in Application Support, not NSTemporaryDirectory(): the
    // OS can purge the temp dir at any time (more aggressively after a
    // kill), which would silently lose a recording requirement #5 needs to
    // survive a relaunch.
    NSString *path = [[self draftsDirectoryURL] URLByAppendingPathComponent:
        [NSString stringWithFormat:@"segment-%@.m4a", [[NSUUID UUID] UUIDString]]].path;
    NSDictionary *settings = @{
        AVFormatIDKey : @(kAudioFormatMPEG4AAC),
        AVSampleRateKey : @(44100),
        AVNumberOfChannelsKey : @(1),
        AVEncoderAudioQualityKey : @(AVAudioQualityHigh),
    };
    self.recorder = [[AVAudioRecorder alloc] initWithURL:[NSURL fileURLWithPath:path]
                                                  settings:settings
                                                     error:&error];
    if (!self.recorder || error) {
        self.statusLabel.text = [NSString stringWithFormat:@"Couldn't create the recorder: %@",
                                                             error.localizedDescription];
        return;
    }
    self.recorder.delegate = self;
    [self.recorder record];

    self.retryButton.hidden = YES;
    self.pendingRetryPath = nil;
    if (self.segmentPaths.count == 0) {
        self.draftStartDate = [NSDate date];
    }
    [self.segmentPaths addObject:path];
    self.currentSegmentStartTime = [NSDate timeIntervalSinceReferenceDate];
    self.recordingState = AutoJournalRecordingStateRecording;
    self.statusLabel.text = @"Recording…";
    [self persistDraftMetadata];
    [self updateUIForState];

    [self.elapsedTimer invalidate];
    self.elapsedTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                          target:self
                                                        selector:@selector(tickElapsed)
                                                        userInfo:nil
                                                         repeats:YES];
}

- (void)tickElapsed {
    NSTimeInterval elapsed = self.accumulatedElapsed +
        ([NSDate timeIntervalSinceReferenceDate] - self.currentSegmentStartTime);
    self.elapsedLabel.text = [self formattedElapsed:elapsed];
}

- (void)pauseRecording {
    // PITFALL: this deliberately calls -stop, not AVAudioRecorder's real
    // -pause. -pause/-record (resume) keeps writing into the SAME file, but
    // only within this process's lifetime -- if the app is killed while
    // paused (not stopped), the m4a container's moov atom is very likely
    // never written, leaving an invalid/unplayable file on relaunch.
    // Calling -stop here finalizes a real, valid, durable file for this
    // segment immediately; -resume (recordButtonTapped, Paused case) starts
    // a fresh AVAudioRecorder on a new file rather than reopening this one.
    // Do not "simplify" this back to -pause/-record.
    [self.recorder stop];
    self.accumulatedElapsed += [NSDate timeIntervalSinceReferenceDate] - self.currentSegmentStartTime;
    [self.elapsedTimer invalidate];
    self.elapsedTimer = nil;
    self.recordingState = AutoJournalRecordingStatePaused;
    self.statusLabel.text = @"Paused";
    [self persistDraftMetadata];
    [self updateUIForState];
}

- (void)cancelButtonTapped {
    if (self.recordingState == AutoJournalRecordingStateRecording) {
        self.discardingSegment = YES;
        [self.recorder stop];
        self.discardingSegment = NO;
    }
    [self deleteAllSegmentsAndDraftMetadata];
    self.segmentPaths = [NSMutableArray array];
    self.accumulatedElapsed = 0;
    self.draftStartDate = nil;
    self.pendingRetryPath = nil;
    self.retryButton.hidden = YES;
    [self.elapsedTimer invalidate];
    self.elapsedTimer = nil;
    self.recordingState = AutoJournalRecordingStateIdle;
    self.elapsedLabel.text = @"00:00";
    self.statusLabel.text = @"Tap to record";
    [self updateUIForState];
}

#pragma mark - AVAudioRecorderDelegate

- (void)audioRecorderDidFinishRecording:(AVAudioRecorder *)recorder successfully:(BOOL)flag {
    if (self.discardingSegment) return; // Cancel already handles cleanup.
    if (flag) return; // Segment finalized fine; pause/save flow tracks it -- no auto-upload here anymore.
    NSString *failedPath = recorder.url.path;
    [self.segmentPaths removeObject:failedPath];
    [[NSFileManager defaultManager] removeItemAtPath:failedPath error:nil];
    [self persistDraftMetadata];
    self.statusLabel.text = @"Recording failed before it could be saved.";
}

#pragma mark - Save (voice)

- (void)saveButtonTapped {
    if (self.recordingState == AutoJournalRecordingStateRecording) {
        [self pauseRecording];
    }
    if (self.segmentPaths.count == 0) return;

    NSString *titleSlug = [self slugifiedTitle];
    self.titleField.text = @""; // matches the note field's existing clear-on-save behavior
    self.statusLabel.text = @"Preparing…";
    self.saveButton.enabled = NO;

    if (self.segmentPaths.count == 1) {
        [self uploadVoiceFileAtPath:self.segmentPaths.firstObject titleSlug:titleSlug];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [self concatenateSegmentsWithCompletion:^(NSString *mergedPath, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!mergedPath) {
            strongSelf.statusLabel.text = [NSString stringWithFormat:@"Couldn't combine the recording: %@",
                                                                       error.localizedDescription];
            strongSelf.saveButton.enabled = YES;
            return;
        }
        // The segments are merged into mergedPath now, so the raw pieces can
        // go; keeping only the merged file means a killed-mid-retry app
        // still has exactly one durable file to resume from.
        for (NSString *segPath in strongSelf.segmentPaths) {
            [[NSFileManager defaultManager] removeItemAtPath:segPath error:nil];
        }
        strongSelf.segmentPaths = [NSMutableArray arrayWithObject:mergedPath];
        [strongSelf persistDraftMetadata];
        [strongSelf uploadVoiceFileAtPath:mergedPath titleSlug:titleSlug];
    }];
}

- (void)uploadVoiceFileAtPath:(NSString *)path titleSlug:(NSString *)titleSlug {
    self.statusLabel.text = @"Uploading…";
    __weak typeof(self) weakSelf = self;
    [self uploadFileAtPath:path
                    isVoice:YES
                  titleSlug:titleSlug
                  onSuccess:^{
        [weakSelf finishVoiceSaveCleanup];
    }];
}

- (void)finishVoiceSaveCleanup {
    [[NSFileManager defaultManager] removeItemAtURL:[self draftMetadataURL] error:nil];
    self.segmentPaths = [NSMutableArray array];
    self.accumulatedElapsed = 0;
    self.draftStartDate = nil;
    self.restoredFromDraft = NO;
    self.recordingState = AutoJournalRecordingStateIdle;
    self.elapsedLabel.text = @"00:00";
    [self updateUIForState];
}

#pragma mark - Concatenation

- (void)concatenateSegmentsWithCompletion:(void (^)(NSString *_Nullable mergedPath,
                                                      NSError *_Nullable error))completion {
    AVMutableComposition *composition = [AVMutableComposition composition];
    AVMutableCompositionTrack *track =
        [composition addMutableTrackWithMediaType:AVMediaTypeAudio
                                  preferredTrackID:kCMPersistentTrackID_Invalid];

    CMTime cursor = kCMTimeZero;
    for (NSString *path in self.segmentPaths) {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
        AVAssetTrack *assetTrack = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
        if (!assetTrack) continue;
        NSError *insertError = nil;
        [track insertTimeRange:CMTimeRangeMake(kCMTimeZero, asset.duration)
                        ofTrack:assetTrack
                         atTime:cursor
                          error:&insertError];
        if (insertError) {
            completion(nil, insertError);
            return;
        }
        cursor = CMTimeAdd(cursor, asset.duration);
    }

    NSString *mergedPath = [[self draftsDirectoryURL] URLByAppendingPathComponent:
        [NSString stringWithFormat:@"merged-%@.m4a", [[NSUUID UUID] UUIDString]]].path;
    [[NSFileManager defaultManager] removeItemAtPath:mergedPath error:nil];

    AVAssetExportSession *export = [[AVAssetExportSession alloc] initWithAsset:composition
                                                                     presetName:AVAssetExportPresetAppleM4A];
    export.outputURL = [NSURL fileURLWithPath:mergedPath];
    export.outputFileType = AVFileTypeAppleM4A;
    [export exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (export.status == AVAssetExportSessionStatusCompleted) {
                completion(mergedPath, nil);
            } else {
                completion(nil, export.error ?: [NSError errorWithDomain:@"AutoJournal" code:-1 userInfo:nil]);
            }
        });
    }];
}

#pragma mark - Text note

- (void)textViewDidBeginEditing:(UITextView *)textView {
    if (textView == self.noteTextView && [textView.textColor isEqual:UIColor.placeholderTextColor]) {
        textView.text = @"";
        textView.textColor = UIColor.labelColor;
    }
}

- (void)textViewDidEndEditing:(UITextView *)textView {
    if (textView == self.noteTextView && textView.text.length == 0) {
        textView.text = kNoteFieldPlaceholder;
        textView.textColor = UIColor.placeholderTextColor;
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)saveNoteTapped {
    NSString *raw = [self.noteTextView.textColor isEqual:UIColor.placeholderTextColor]
        ? @""
        : self.noteTextView.text;
    NSString *text = [raw stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length == 0) return;
    [self.noteTextView resignFirstResponder];

    NSString *titleSlug = [self slugifiedTitle];
    self.titleField.text = @"";

    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"journal-note-%@.txt", [[NSUUID UUID] UUIDString]]];
    NSError *error = nil;
    [data writeToFile:path options:NSDataWritingAtomic error:&error];
    if (error) {
        self.statusLabel.text = [NSString stringWithFormat:@"Couldn't save the note: %@",
                                                             error.localizedDescription];
        return;
    }

    self.statusLabel.text = @"Uploading note…";
    self.noteTextView.text = kNoteFieldPlaceholder;
    self.noteTextView.textColor = UIColor.placeholderTextColor;
    [self uploadFileAtPath:path isVoice:NO titleSlug:titleSlug onSuccess:nil];
}

#pragma mark - Title slug

- (NSString *)slugifiedTitle {
    NSString *trimmed = [self.titleField.text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return nil;

    NSString *lower = trimmed.lowercaseString;
    NSMutableString *slug = [NSMutableString string];
    BOOL lastWasHyphen = NO;
    for (NSUInteger i = 0; i < lower.length; i++) {
        unichar c = [lower characterAtIndex:i];
        BOOL isAlnum = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
        if (isAlnum) {
            [slug appendFormat:@"%C", c];
            lastWasHyphen = NO;
        } else if (!lastWasHyphen && slug.length > 0) {
            [slug appendString:@"-"];
            lastWasHyphen = YES;
        }
    }
    while (slug.length > 0 && [slug hasSuffix:@"-"]) {
        [slug deleteCharactersInRange:NSMakeRange(slug.length - 1, 1)];
    }

    static const NSUInteger kMaxSlugLength = 40;
    if (slug.length > kMaxSlugLength) {
        [slug deleteCharactersInRange:NSMakeRange(kMaxSlugLength, slug.length - kMaxSlugLength)];
        while (slug.length > 0 && [slug hasSuffix:@"-"]) {
            [slug deleteCharactersInRange:NSMakeRange(slug.length - 1, 1)];
        }
    }
    return slug.length > 0 ? slug : nil;
}

#pragma mark - Draft persistence

- (NSURL *)draftsDirectoryURL {
    NSArray<NSURL *> *urls = [[NSFileManager defaultManager]
        URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask];
    NSURL *base = urls.firstObject;
    NSURL *dir = [base URLByAppendingPathComponent:@"JournalDrafts" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return dir;
}

- (NSURL *)draftMetadataURL {
    return [[self draftsDirectoryURL] URLByAppendingPathComponent:@"draft.json"];
}

- (void)persistDraftMetadata {
    if (self.segmentPaths.count == 0) {
        [[NSFileManager defaultManager] removeItemAtURL:[self draftMetadataURL] error:nil];
        return;
    }
    NSDictionary *json = @{
        @"segments" : self.segmentPaths,
        @"title" : self.titleField.text ?: @"",
        @"startedAt" : @(self.draftStartDate.timeIntervalSince1970),
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    [data writeToURL:[self draftMetadataURL] atomically:YES];
}

- (void)loadDraftIfPresent {
    NSData *data = [NSData dataWithContentsOfURL:[self draftMetadataURL]];
    if (!data) return;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return;

    NSArray *segments = json[@"segments"];
    if (![segments isKindOfClass:[NSArray class]]) return;

    NSMutableArray<NSString *> *validSegments = [NSMutableArray array];
    for (id path in segments) {
        if ([path isKindOfClass:[NSString class]] &&
            [[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [validSegments addObject:path];
        }
    }
    if (validSegments.count == 0) {
        [[NSFileManager defaultManager] removeItemAtURL:[self draftMetadataURL] error:nil];
        return;
    }

    self.segmentPaths = validSegments;
    id title = json[@"title"];
    self.titleField.text = [title isKindOfClass:[NSString class]] ? title : @"";

    NSNumber *startedAt = json[@"startedAt"];
    self.draftStartDate = [startedAt isKindOfClass:[NSNumber class]]
        ? [NSDate dateWithTimeIntervalSince1970:startedAt.doubleValue]
        : [NSDate date];

    self.accumulatedElapsed = [self totalDurationOfSegments:validSegments];
    self.recordingState = AutoJournalRecordingStatePaused;
    self.restoredFromDraft = YES;

    self.modeControl.selectedSegmentIndex = 0; // the paused voice UI is where the draft lives
    [self modeChanged:nil];

    self.elapsedLabel.text = [self formattedElapsed:self.accumulatedElapsed];
    self.statusLabel.text = @"Paused";

    static NSDateFormatter *timeFormatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        timeFormatter = [[NSDateFormatter alloc] init];
        timeFormatter.dateFormat = @"HH:mm";
    });
    self.draftBannerLabel.text = [NSString stringWithFormat:
        @"Unsaved recording from %@ — Resume, Save, or Cancel below.",
        [timeFormatter stringFromDate:self.draftStartDate]];
    self.draftBannerLabel.hidden = NO;

    [self updateUIForState];
}

- (void)deleteAllSegmentsAndDraftMetadata {
    for (NSString *path in self.segmentPaths) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
    [[NSFileManager defaultManager] removeItemAtURL:[self draftMetadataURL] error:nil];
    self.restoredFromDraft = NO;
}

- (NSTimeInterval)totalDurationOfSegments:(NSArray<NSString *> *)paths {
    NSTimeInterval total = 0;
    for (NSString *path in paths) {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
        total += CMTimeGetSeconds(asset.duration);
    }
    return total;
}

- (NSString *)formattedElapsed:(NSTimeInterval)elapsed {
    NSInteger minutes = (NSInteger)elapsed / 60;
    NSInteger seconds = (NSInteger)elapsed % 60;
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)minutes, (long)seconds];
}

#pragma mark - Upload

- (NSString *)filenameTimestamp {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd-HHmmss";
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    return [formatter stringFromDate:[NSDate date]];
}

- (void)uploadFileAtPath:(NSString *)path
                  isVoice:(BOOL)isVoice
                titleSlug:(nullable NSString *)titleSlug
                onSuccess:(void (^_Nullable)(void))onSuccess {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"no data at %@ to upload", path];
    }

    NSString *timestamp = [self filenameTimestamp];
    NSString *suffix = titleSlug.length > 0 ? [NSString stringWithFormat:@"-%@", titleSlug] : @"";
    // The backend's /drop routing only pattern-matches the journal-voice-/
    // journal-note- prefix via regex, so appending the slug after the
    // timestamp and before the extension is safe with no backend change.
    NSString *filename = isVoice
        ? [NSString stringWithFormat:@"journal-voice-%@%@.m4a", timestamp, suffix]
        : [NSString stringWithFormat:@"journal-note-%@%@.txt", timestamp, suffix];

    self.pendingRetryPath = nil;
    __weak typeof(self) weakSelf = self;
    [GLDropUploader uploadData:data
                       filename:filename
                    contentType:@"application/octet-stream"
                     toEndpoint:GLEndpointURL(@"/drop").absoluteString
                          token:GL_BAKED_TOKEN
                     completion:^(NSString *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (error) {
                strongSelf.statusLabel.text = [NSString stringWithFormat:
                    @"Upload failed: %@. The recording is kept on-device.", error];
                strongSelf.pendingRetryPath = path;
                strongSelf.pendingRetryIsVoice = isVoice;
                strongSelf.pendingRetryTitleSlug = titleSlug;
                strongSelf.retryButton.hidden = NO;
                strongSelf.saveButton.enabled = YES;
            } else {
                strongSelf.statusLabel.text = @"Saved.";
                strongSelf.retryButton.hidden = YES;
                strongSelf.pendingRetryPath = nil;
                [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
                if (onSuccess) onSuccess();
            }
        });
    }];
}

- (void)retryTapped {
    if (!self.pendingRetryPath) return;
    NSString *path = self.pendingRetryPath;
    BOOL isVoice = self.pendingRetryIsVoice;
    NSString *titleSlug = self.pendingRetryTitleSlug;
    self.statusLabel.text = @"Retrying upload…";
    __weak typeof(self) weakSelf = self;
    [self uploadFileAtPath:path
                    isVoice:isVoice
                  titleSlug:titleSlug
                  onSuccess:isVoice ? ^{ [weakSelf finishVoiceSaveCleanup]; } : nil];
}

@end
