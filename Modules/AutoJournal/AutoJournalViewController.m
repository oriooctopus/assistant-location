#import "AutoJournalViewController.h"

#import <AVFoundation/AVFoundation.h>

#import "BakedConfig.h"
#import "GLEndpoints.h"
#import "GLDropUploader.h"
#import "RecentRecordingsViewController.h"

static NSString *const kJournalStartCaptureNotification = @"GLJournalStartCapture";

@interface AutoJournalViewController () <AVAudioRecorderDelegate, UITextFieldDelegate>

@property(nonatomic, strong) UITextField *noteField;
@property(nonatomic, strong) UIButton *saveNoteButton;

@property(nonatomic, strong) UIButton *recordButton;
@property(nonatomic, strong) UILabel *elapsedLabel;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIButton *retryButton;

@property(nonatomic, strong) AVAudioRecorder *recorder;
@property(nonatomic, strong) NSTimer *elapsedTimer;
@property(nonatomic, assign) NSTimeInterval recordingStartTime;
@property(nonatomic, copy) NSString *pendingRetryPath;
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

    [self buildNoteEntry];
    [self buildRecorder];
}

- (void)recentTapped {
    [self.navigationController pushViewController:[[RecentRecordingsViewController alloc] init]
                                          animated:YES];
}

- (void)buildNoteEntry {
    self.noteField = [[UITextField alloc] init];
    self.noteField.placeholder = @"Type a short entry";
    self.noteField.borderStyle = UITextBorderStyleRoundedRect;
    self.noteField.returnKeyType = UIReturnKeyDone;
    self.noteField.delegate = self;
    self.noteField.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.noteField];

    self.saveNoteButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.saveNoteButton setTitle:@"Save" forState:UIControlStateNormal];
    self.saveNoteButton.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [self.saveNoteButton addTarget:self
                             action:@selector(saveNoteTapped)
                   forControlEvents:UIControlEventTouchUpInside];
    self.saveNoteButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.saveNoteButton];

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.noteField.topAnchor constraintEqualToAnchor:guide.topAnchor constant:24],
        [self.noteField.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:20],
        [self.saveNoteButton.leadingAnchor constraintEqualToAnchor:self.noteField.trailingAnchor
                                                            constant:12],
        [self.saveNoteButton.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor
                                                             constant:-20],
        [self.saveNoteButton.centerYAnchor constraintEqualToAnchor:self.noteField.centerYAnchor],
        [self.saveNoteButton.widthAnchor constraintEqualToConstant:60],
    ]];
}

- (void)buildRecorder {
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
    ]];
}

#pragma mark - Lock-screen Control handoff

- (void)handleStartCaptureNotification {
    [self selectJournalTab];

    if (self.recorder.recording) return;
    [self beginRecordingFlow];
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

#pragma mark - Recording

- (void)recordButtonTapped {
    if (self.recorder.recording) {
        [self stopRecording];
    } else {
        [self beginRecordingFlow];
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

    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"journal-%@.m4a", [[NSUUID UUID] UUIDString]]];
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
    self.recordingStartTime = [NSDate timeIntervalSinceReferenceDate];
    [self.recordButton setImage:[UIImage systemImageNamed:@"stop.circle.fill"]
                        forState:UIControlStateNormal];
    self.statusLabel.text = @"Recording…";
    [self.elapsedTimer invalidate];
    self.elapsedTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                          target:self
                                                        selector:@selector(tickElapsed)
                                                        userInfo:nil
                                                         repeats:YES];
}

- (void)tickElapsed {
    NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - self.recordingStartTime;
    NSInteger minutes = (NSInteger)elapsed / 60;
    NSInteger seconds = (NSInteger)elapsed % 60;
    self.elapsedLabel.text = [NSString stringWithFormat:@"%02ld:%02ld", (long)minutes, (long)seconds];
}

- (void)stopRecording {
    [self.recorder stop];
    [self.elapsedTimer invalidate];
    self.elapsedTimer = nil;
    [self.recordButton setImage:[UIImage systemImageNamed:@"mic.circle.fill"]
                        forState:UIControlStateNormal];
}

#pragma mark - AVAudioRecorderDelegate

- (void)audioRecorderDidFinishRecording:(AVAudioRecorder *)recorder successfully:(BOOL)flag {
    if (!flag) {
        self.statusLabel.text = @"Recording failed before it could be saved.";
        return;
    }
    self.statusLabel.text = @"Uploading…";
    NSString *timestamp = [self filenameTimestamp];
    NSString *filename = [NSString stringWithFormat:@"journal-voice-%@.m4a", timestamp];
    [self uploadFileAtPath:recorder.url.path filename:filename contentType:@"application/octet-stream"];
}

#pragma mark - Text note

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self saveNoteTapped];
    return YES;
}

- (void)saveNoteTapped {
    NSString *text = [self.noteField.text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length == 0) return;
    [self.noteField resignFirstResponder];

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
    NSString *filename = [NSString stringWithFormat:@"journal-note-%@.txt", [self filenameTimestamp]];
    [self uploadFileAtPath:path filename:filename contentType:@"application/octet-stream"];
    self.noteField.text = @"";
}

#pragma mark - Upload

- (NSString *)filenameTimestamp {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd-HHmmss";
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    return [formatter stringFromDate:[NSDate date]];
}

- (void)uploadFileAtPath:(NSString *)path filename:(NSString *)filename contentType:(NSString *)contentType {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"no data at %@ to upload", path];
    }
    __weak typeof(self) weakSelf = self;
    [GLDropUploader uploadData:data
                       filename:filename
                    contentType:contentType
                     toEndpoint:GLEndpointURL(@"/drop").absoluteString
                          token:GL_BAKED_TOKEN
                     completion:^(NSString *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (error) {
                strongSelf.statusLabel.text = [NSString stringWithFormat:@"Upload failed: %@. The recording is kept on-device.", error];
                strongSelf.pendingRetryPath = path;
                strongSelf.retryButton.hidden = NO;
            } else {
                strongSelf.statusLabel.text = @"Saved.";
                strongSelf.retryButton.hidden = YES;
                strongSelf.pendingRetryPath = nil;
                [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            }
        });
    }];
}

- (void)retryTapped {
    if (!self.pendingRetryPath) return;
    NSString *path = self.pendingRetryPath;
    BOOL isVoice = [path.pathExtension isEqualToString:@"m4a"];
    NSString *filename = isVoice
        ? [NSString stringWithFormat:@"journal-voice-%@.m4a", [self filenameTimestamp]]
        : [NSString stringWithFormat:@"journal-note-%@.txt", [self filenameTimestamp]];
    self.statusLabel.text = @"Retrying upload…";
    [self uploadFileAtPath:path filename:filename contentType:@"application/octet-stream"];
}

@end
