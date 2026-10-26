#import "ClipPlayerViewController.h"

#import <AVFoundation/AVFoundation.h>

#import "ClipsNotesStore.h"
#import "GLFormat.h"
#import "GLLog.h"
#import "GLTheme.h"

static const NSTimeInterval kSkipSeconds = 5;

@interface ClipPlayerViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *clipID;
@property (nonatomic, copy) NSString *clipTitle;
@property (nonatomic, strong) NSURL *fileURL;
@property (nonatomic, strong) ClipsNotesStore *store;
@property (nonatomic, copy) NSArray<NSDictionary *> *notes;

@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) id timeObserver;
@property (nonatomic) float speed;
@property (nonatomic) BOOL looping;
@property (nonatomic) BOOL wantsPlay; // play/pause intent; AVPlayer.rate is 0 while paused

@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *elapsedLabel;
@property (nonatomic, strong) UILabel *totalLabel;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIButton *loopButton;
@property (nonatomic, strong) UILabel *speedLabel;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic) BOOL scrubbing;
@property (nonatomic) BOOL hooksRan;
@end

@implementation ClipPlayerViewController

+ (NSArray<NSNumber *> *)speedSteps { return @[@0.5, @0.75, @1.0, @1.25, @1.5]; }

- (instancetype)initWithClipID:(NSString *)clipID title:(NSString *)title fileURL:(NSURL *)fileURL notes:(ClipsNotesStore *)notes {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _clipID = [clipID copy];
        _clipTitle = [title copy];
        _fileURL = fileURL;
        _store = notes;
        _notes = [notes notesForClip:clipID];
        NSNumber *saved = [[NSUserDefaults standardUserDefaults] objectForKey:[self speedKey]];
        _speed = saved ? saved.floatValue : 1.0f;
    }
    return self;
}

- (NSString *)speedKey { return [@"ClipsSpeed." stringByAppendingString:self.clipID]; }

#pragma mark - View

- (UIButton *)symbolButton:(NSString *)symbol action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:26];
    [b setImage:[UIImage systemImageNamed:symbol withConfiguration:cfg] forState:UIControlStateNormal];
    b.tintColor = [GLTheme accentColor];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UILabel *)labelWithFont:(UIFont *)font color:(UIColor *)color {
    UILabel *l = [[UILabel alloc] init];
    l.font = font;
    l.textColor = color;
    return l;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [GLTheme backgroundColor];

    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    [done setTitle:@"Done" forState:UIControlStateNormal];
    done.titleLabel.font = [GLTheme buttonFont];
    done.tintColor = [GLTheme accentColor];
    [done addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];

    self.titleLabel = [self labelWithFont:[GLTheme titleFont] color:[GLTheme textPrimaryColor]];
    self.titleLabel.text = self.clipTitle;
    self.titleLabel.numberOfLines = 0;

    self.slider = [[UISlider alloc] init];
    self.slider.tintColor = [GLTheme accentColor];
    [self.slider addTarget:self action:@selector(scrubBegan) forControlEvents:UIControlEventTouchDown];
    [self.slider addTarget:self action:@selector(scrubChanged) forControlEvents:UIControlEventValueChanged];
    [self.slider addTarget:self action:@selector(scrubEnded) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    self.elapsedLabel = [self labelWithFont:[GLTheme monoDigitFont] color:[GLTheme textSecondaryColor]];
    self.totalLabel = [self labelWithFont:[GLTheme monoDigitFont] color:[GLTheme textSecondaryColor]];
    self.totalLabel.textAlignment = NSTextAlignmentRight;

    self.playButton = [self symbolButton:@"play.fill" action:@selector(togglePlay)];
    UIButton *back = [self symbolButton:@"gobackward.5" action:@selector(skipBack)];
    UIButton *forward = [self symbolButton:@"goforward.5" action:@selector(skipForward)];
    self.loopButton = [self symbolButton:@"repeat" action:@selector(toggleLoop)];
    UIStackView *transport = [[UIStackView alloc] initWithArrangedSubviews:@[self.loopButton, back, self.playButton, forward]];
    transport.distribution = UIStackViewDistributionEqualSpacing;

    UIButton *slower = [self symbolButton:@"minus.circle" action:@selector(slowDown)];
    UIButton *faster = [self symbolButton:@"plus.circle" action:@selector(speedUp)];
    self.speedLabel = [self labelWithFont:[GLTheme monoDigitFont] color:[GLTheme textPrimaryColor]];
    self.speedLabel.textAlignment = NSTextAlignmentCenter;
    UIStackView *speedRow = [[UIStackView alloc] initWithArrangedSubviews:@[slower, self.speedLabel, faster]];
    speedRow.distribution = UIStackViewDistributionEqualCentering;

    UIButton *add = [UIButton buttonWithType:UIButtonTypeSystem];
    [add setTitle:@"Add note" forState:UIControlStateNormal];
    add.titleLabel.font = [GLTheme buttonFont];
    add.tintColor = [GLTheme accentColor];
    [add addTarget:self action:@selector(promptNewNote) forControlEvents:UIControlEventTouchUpInside];

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.backgroundColor = [UIColor clearColor];
    self.table.separatorColor = [GLTheme textSecondaryColor];

    UIStackView *times = [[UIStackView alloc] initWithArrangedSubviews:@[self.elapsedLabel, self.totalLabel]];
    times.distribution = UIStackViewDistributionFillEqually;
    UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:@[done, self.titleLabel, self.slider, times, transport, speedRow, add, self.table]];
    column.axis = UILayoutConstraintAxisVertical;
    column.spacing = [GLTheme spacingM];
    column.alignment = UIStackViewAlignmentFill;
    column.translatesAutoresizingMaskIntoConstraints = NO;
    done.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    [self.view addSubview:column];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [column.topAnchor constraintEqualToAnchor:safe.topAnchor constant:[GLTheme spacingS]],
        [column.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [column.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:[GLTheme spacingM]],
        [column.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-[GLTheme spacingM]],
    ]];

    [self setUpPlayer];
    [self refreshControls];
}

- (void)setUpPlayer {
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (![session setCategory:AVAudioSessionCategoryPlayback error:&error] || ![session setActive:YES error:&error]) {
        [NSException raise:NSInternalInconsistencyException format:@"Clips: audio session: %@", error];
    }
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:self.fileURL];
    item.audioTimePitchAlgorithm = AVAudioTimePitchAlgorithmSpectral; // keep pitch at any speed
    self.player = [AVPlayer playerWithPlayerItem:item];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(itemEnded)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification object:item];
    __weak typeof(self) weakSelf = self;
    self.timeObserver = [self.player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.25, 600)
                                                                  queue:dispatch_get_main_queue()
                                                             usingBlock:^(CMTime time) { [weakSelf refreshTime]; }];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.player.currentItem) return;
    if (!self.wantsPlay && self.player.currentTime.value == 0) [self play];
    if (!self.hooksRan) {
        self.hooksRan = YES;
        [self runTestHooks];
    }
}

- (void)dealloc {
    [self.player removeTimeObserver:self.timeObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)close {
    [self.player pause];
    self.wantsPlay = NO;
    [self dismissViewControllerAnimated:NO completion:nil];
}

#pragma mark - Transport

- (NSTimeInterval)duration {
    NSTimeInterval d = CMTimeGetSeconds(self.player.currentItem.duration);
    return isfinite(d) ? d : 0;
}

- (NSTimeInterval)elapsed { return CMTimeGetSeconds(self.player.currentTime); }

- (void)play {
    self.wantsPlay = YES;
    self.player.rate = self.speed; // setting a non-zero rate starts playback
    [self refreshControls];
}

- (void)pause {
    self.wantsPlay = NO;
    [self.player pause];
    [self refreshControls];
}

- (void)togglePlay { self.wantsPlay ? [self pause] : [self play]; }

- (void)seekTo:(NSTimeInterval)seconds {
    NSTimeInterval clamped = MAX(0, MIN(seconds, self.duration));
    [self.player seekToTime:CMTimeMakeWithSeconds(clamped, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    [self refreshTime];
}

- (void)skipBack { [self seekTo:self.elapsed - kSkipSeconds]; }
- (void)skipForward { [self seekTo:self.elapsed + kSkipSeconds]; }

- (void)toggleLoop {
    self.looping = !self.looping;
    [self refreshControls];
}

- (void)itemEnded {
    [self seekTo:0];
    if (self.looping) [self play]; else [self pause];
}

- (void)scrubBegan { self.scrubbing = YES; }
- (void)scrubChanged { self.elapsedLabel.text = GLFormatDuration(self.slider.value); }
- (void)scrubEnded {
    self.scrubbing = NO;
    [self seekTo:self.slider.value];
}

#pragma mark - Speed

- (NSUInteger)speedIndex {
    NSArray<NSNumber *> *steps = [ClipPlayerViewController speedSteps];
    for (NSUInteger i = 0; i < steps.count; i++) if (fabsf(steps[i].floatValue - self.speed) < 0.001f) return i;
    [NSException raise:NSInternalInconsistencyException format:@"Clips: saved speed %.3f is not a step", self.speed];
    return 0;
}

- (void)stepSpeedBy:(NSInteger)delta {
    NSArray<NSNumber *> *steps = [ClipPlayerViewController speedSteps];
    NSInteger index = MAX(0, MIN((NSInteger)steps.count - 1, (NSInteger)[self speedIndex] + delta));
    self.speed = steps[index].floatValue;
    [[NSUserDefaults standardUserDefaults] setFloat:self.speed forKey:[self speedKey]];
    if (self.wantsPlay) self.player.rate = self.speed;
    [self refreshControls];
}

- (void)slowDown { [self stepSpeedBy:-1]; }
- (void)speedUp { [self stepSpeedBy:1]; }

#pragma mark - Display

- (void)refreshControls {
    [self.playButton setImage:[UIImage systemImageNamed:self.wantsPlay ? @"pause.fill" : @"play.fill"
                                      withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:34]]
                     forState:UIControlStateNormal];
    self.loopButton.tintColor = self.looping ? [GLTheme accentColor] : [GLTheme textSecondaryColor];
    self.speedLabel.text = [NSString stringWithFormat:@"%gx", self.speed];
    [self refreshTime];
}

- (void)refreshTime {
    self.slider.maximumValue = MAX(self.duration, 1);
    if (!self.scrubbing) {
        self.slider.value = self.elapsed;
        self.elapsedLabel.text = GLFormatDuration(self.elapsed);
    }
    self.totalLabel.text = GLFormatDuration(self.duration);
}

#pragma mark - Notes

- (void)addNoteWithText:(NSString *)text {
    [self.store addNoteToClip:self.clipID time:self.elapsed text:text];
    [self reloadNotes];
}

- (void)reloadNotes {
    self.notes = [self.store notesForClip:self.clipID];
    [self.table reloadData];
}

- (void)promptNoteWithTitle:(NSString *)title text:(NSString *)text action:(NSString *)action done:(void (^)(NSString *))done {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.text = text; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:action style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *value = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (value.length) done(value);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)promptNewNote {
    [self promptNoteWithTitle:GLFormatDuration(self.elapsed) text:nil action:@"Add" done:^(NSString *text) { [self addNoteWithText:text]; }];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.notes.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"note"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"note"];
    NSDictionary *note = self.notes[indexPath.row];
    cell.backgroundColor = [GLTheme surfaceColor];
    cell.textLabel.text = note[@"text"];
    cell.textLabel.font = [GLTheme bodyFont];
    cell.textLabel.textColor = [GLTheme textPrimaryColor];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.text = GLFormatDuration([note[@"time"] doubleValue]);
    cell.detailTextLabel.font = [GLTheme monoDigitFont];
    cell.detailTextLabel.textColor = [GLTheme accentColor];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self seekTo:[self.notes[indexPath.row][@"time"] doubleValue]];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *note = self.notes[indexPath.row];
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete"
                                                                       handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [self.store deleteNote:note[@"id"] inClip:self.clipID];
        [self reloadNotes];
        done(YES);
    }];
    UIContextualAction *edit = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Edit"
                                                                     handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [self promptNoteWithTitle:GLFormatDuration([note[@"time"] doubleValue]) text:note[@"text"] action:@"Save" done:^(NSString *text) {
            [self.store setText:text ofNote:note[@"id"] inClip:self.clipID];
            [self reloadNotes];
        }];
        done(YES);
    }];
    edit.backgroundColor = [GLTheme accentColor];
    return [UISwipeActionsConfiguration configurationWithActions:@[delete, edit]];
}

#pragma mark - sim-test hooks

/// Drives the real controls and reports what the player did, for sim-test:
/// UITEST_CLIPS_SPEED=<rate> taps the speed button until it reaches that
/// step, UITEST_CLIPS_NOTE=<text> adds a note at the current time, and
/// UITEST_REPORT_CLIPS=1 logs the result 4 seconds after the player opens.
- (void)runTestHooks {
    NSDictionary *env = [[NSProcessInfo processInfo] environment];
    if (env[@"UITEST_CLIPS_SPEED"]) {
        float target = [env[@"UITEST_CLIPS_SPEED"] floatValue];
        for (int i = 0; i < 10 && fabsf(self.speed - target) > 0.001f; i++) {
            target > self.speed ? [self speedUp] : [self slowDown];
        }
    }
    if (env[@"UITEST_CLIPS_NOTE"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self addNoteWithText:env[@"UITEST_CLIPS_NOTE"]];
        });
    }
    if (env[@"UITEST_REPORT_CLIPS"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            NSLog(@"UITEST_CLIPS_REPORT onScreen=%d id=%@ playing=%d rate=%.2f speed=%.2f time=%.2f notes=%lu loop=%d",
                  self.view.window != nil, self.clipID, self.wantsPlay, self.player.rate, self.speed, self.elapsed,
                  (unsigned long)self.notes.count, self.looping);
        });
    }
}

@end
