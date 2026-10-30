#import "ClipPlayerViewController.h"

#import <AVFoundation/AVFoundation.h>

#import "ClipScoreViewController.h"
#import "ClipsNotesStore.h"
#import "ClipsSectionsStore.h"
#import "ClipsVoiceCommand.h"
#import "ClipsVoiceListener.h"
#import "GLFormat.h"
#import "GLLog.h"
#import "GLTheme.h"

static const NSTimeInterval kSkipSeconds = 5;
static const NSTimeInterval kNudgeSeconds = 0.5;
static const NSTimeInterval kMinSectionLength = 0.1;
static const CGFloat kTocRowHeight = 36;
static const NSUInteger kTocMaxVisibleRows = 7;
static const NSTimeInterval kVoiceSilenceSeconds = 2.5; // a pause this long ends the dictation

/// Row times: "0:14", no leading zero on minutes.
static NSString *RowTime(NSTimeInterval t) {
    int total = (int)t;
    return [NSString stringWithFormat:@"%d:%02d", total / 60, total % 60];
}

static NSString *SectionTime(NSTimeInterval t) {
    int minutes = (int)(t / 60);
    return [NSString stringWithFormat:@"%d:%04.1f", minutes, t - minutes * 60];
}

/// Section boundaries drawn over the scrub bar's track (touches pass through to the slider).
@interface ClipsTickView : UIView
@property (nonatomic, weak) UISlider *slider;
@property (nonatomic, copy) NSArray<NSNumber *> *boundaries; // seconds
@property (nonatomic) NSTimeInterval duration;
@end

@implementation ClipsTickView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    if (self.duration <= 0) return;
    CGRect track = [self.slider trackRectForBounds:self.slider.bounds];
    [[GLTheme textPrimaryColor] setFill];
    for (NSNumber *b in self.boundaries) {
        double t = b.doubleValue;
        if (t <= 0 || t >= self.duration) continue;
        CGFloat x = track.origin.x + track.size.width * (t / self.duration);
        UIRectFill(CGRectMake(x - 1, CGRectGetMidY(track) - 9, 2, 18));
    }
}
@end

@interface ClipPlayerViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *clipID;
@property (nonatomic, copy) NSString *clipTitle;
@property (nonatomic, strong) NSURL *fileURL;
@property (nonatomic, strong) NSURL *scoreURL;
@property (nonatomic, strong) ClipsVoiceListener *listener; // non-nil while dictating
@property (nonatomic, strong) NSTimer *voiceSilenceTimer;
@property (nonatomic, strong) UIButton *voiceButton;
@property (nonatomic, strong) UILabel *voiceStatus;
@property (nonatomic, copy) NSString *voiceText;
@property (nonatomic) NSTimeInterval voicePlayhead;        // where the mic was tapped
@property (nonatomic) BOOL voiceResumes;                   // was playing when the mic was tapped
@property (nonatomic, strong) ClipsNotesStore *store;
@property (nonatomic, copy) NSArray<NSDictionary *> *notes;
@property (nonatomic, strong) ClipsSectionsStore *sectionStore;
@property (nonatomic, copy) NSArray<NSDictionary *> *sections;
@property (nonatomic, copy) NSString *sectionReference;
@property (nonatomic, copy) NSString *selectedSectionID;   // edit + loop target
@property (nonatomic, copy) NSString *playingSectionID;    // the one the playhead is in
@property (nonatomic) BOOL started;
@property (nonatomic) NSInteger seeksInFlight;             // currentTime is stale until these finish
@property (nonatomic) BOOL loopEntered;                    // playhead has reached the section since the bounds were set
@property (nonatomic) NSInteger wraps;                     // section-loop wraps since the bounds were last set
@property (nonatomic) NSTimeInterval loopMin, loopMax;     // playhead extremes seen while looping a section
@property (nonatomic, strong) UIStackView *editor;
@property (nonatomic, strong) UITableView *tocTable;
@property (nonatomic, strong) NSLayoutConstraint *tocHeight;
@property (nonatomic, strong) ClipsTickView *ticks;
@property (nonatomic, strong) UIButton *editToggle;
@property (nonatomic, strong) UILabel *editName;
@property (nonatomic, strong) UILabel *startValue;
@property (nonatomic, strong) UILabel *endValue;

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
@end

@implementation ClipPlayerViewController

+ (NSArray<NSNumber *> *)speedSteps { return @[@0.5, @0.75, @1.0, @1.25, @1.5]; }

- (instancetype)initWithClipID:(NSString *)clipID title:(NSString *)title fileURL:(NSURL *)fileURL scoreURL:(NSURL *)scoreURL notes:(ClipsNotesStore *)notes sections:(ClipsSectionsStore *)sections sectionReference:(NSString *)sectionReference {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _clipID = [clipID copy];
        _clipTitle = [title copy];
        _fileURL = fileURL;
        _scoreURL = scoreURL;
        _store = notes;
        _notes = [notes notesForClip:clipID];
        _sectionStore = sections;
        _sections = [sections sectionsForClip:clipID];
        _sectionReference = [sectionReference copy];
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
    self.ticks = [[ClipsTickView alloc] init];
    self.ticks.slider = self.slider;
    UIView *sliderHost = [[UIView alloc] init];
    for (UIView *v in @[self.slider, self.ticks]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [sliderHost addSubview:v];
        [NSLayoutConstraint activateConstraints:@[
            [v.leadingAnchor constraintEqualToAnchor:sliderHost.leadingAnchor],
            [v.trailingAnchor constraintEqualToAnchor:sliderHost.trailingAnchor],
            [v.topAnchor constraintEqualToAnchor:sliderHost.topAnchor],
            [v.bottomAnchor constraintEqualToAnchor:sliderHost.bottomAnchor],
        ]];
    }
    [sliderHost.heightAnchor constraintEqualToConstant:32].active = YES;
    self.elapsedLabel = [self labelWithFont:[GLTheme monoDigitFont] color:[GLTheme textSecondaryColor]];
    self.totalLabel = [self labelWithFont:[GLTheme monoDigitFont] color:[GLTheme textSecondaryColor]];
    self.totalLabel.textAlignment = NSTextAlignmentRight;

    self.playButton = [self symbolButton:@"play.fill" action:@selector(togglePlay)];
    UIButton *back = [self symbolButton:@"gobackward.5" action:@selector(skipBack)];
    UIButton *forward = [self symbolButton:@"goforward.5" action:@selector(skipForward)];
    self.loopButton = [self symbolButton:@"repeat" action:@selector(toggleLoop)];
    UIButton *prevSection = [self symbolButton:@"backward.end.fill" action:@selector(previousSection)];
    UIButton *nextSection = [self symbolButton:@"forward.end.fill" action:@selector(nextSection)];
    UIStackView *transport = [[UIStackView alloc] initWithArrangedSubviews:@[self.loopButton, prevSection, back, self.playButton, forward, nextSection]];
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

    self.tocTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tocTable.dataSource = self;
    self.tocTable.delegate = self;
    self.tocTable.backgroundColor = [UIColor clearColor];
    self.tocTable.separatorColor = [GLTheme textSecondaryColor];
    self.tocTable.rowHeight = kTocRowHeight;
    self.tocHeight = [self.tocTable.heightAnchor constraintEqualToConstant:kTocRowHeight];
    self.tocHeight.active = YES;

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.backgroundColor = [UIColor clearColor];
    self.table.separatorColor = [GLTheme textSecondaryColor];

    self.editToggle = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.editToggle setTitle:@"Edit" forState:UIControlStateNormal];
    self.editToggle.titleLabel.font = [GLTheme buttonFont];
    self.editToggle.tintColor = [GLTheme accentColor];
    [self.editToggle addTarget:self action:@selector(toggleEditing) forControlEvents:UIControlEventTouchUpInside];
    self.voiceButton = [self symbolButton:@"mic.fill" action:@selector(toggleVoice)];
    self.voiceButton.accessibilityLabel = @"Voice note";
    UIButton *scoreButton = [self symbolButton:@"music.note.list" action:@selector(openScore)];
    scoreButton.accessibilityLabel = @"Sheet music";
    scoreButton.hidden = !self.scoreURL;
    UIStackView *addRow = [[UIStackView alloc] initWithArrangedSubviews:@[add, self.voiceButton, scoreButton, self.editToggle]];
    addRow.distribution = UIStackViewDistributionFillEqually;
    self.voiceStatus = [self labelWithFont:[GLTheme bodyFont] color:[GLTheme textSecondaryColor]];
    self.voiceStatus.numberOfLines = 0;
    self.voiceStatus.hidden = YES;

    self.startValue = [self labelWithFont:[GLTheme monoDigitFont] color:[GLTheme textPrimaryColor]];
    self.endValue = [self labelWithFont:[GLTheme monoDigitFont] color:[GLTheme textPrimaryColor]];
    self.editName = [self labelWithFont:[GLTheme bodyFont] color:[GLTheme textPrimaryColor]];
    __weak typeof(self) weakSelf = self;
    UIStackView *editActions = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self textButton:@"Rename" handler:^{ [weakSelf renameSelected]; }],
        [self textButton:@"Add section" handler:^{ [weakSelf addSectionHere]; }],
        [self textButton:@"Delete" handler:^{ [weakSelf deleteSelected]; }],
    ]];
    editActions.distribution = UIStackViewDistributionFillEqually;
    self.editor = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.editName,
        [self editRowNamed:@"Start" value:self.startValue isStart:YES],
        [self editRowNamed:@"End" value:self.endValue isStart:NO],
        editActions,
    ]];
    self.editor.hidden = YES;
    self.editor.axis = UILayoutConstraintAxisVertical;
    self.editor.spacing = [GLTheme spacingS];

    UIStackView *times = [[UIStackView alloc] initWithArrangedSubviews:@[self.elapsedLabel, self.totalLabel]];
    times.distribution = UIStackViewDistributionFillEqually;
    UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:@[done, self.titleLabel, sliderHost, times, transport, speedRow, self.tocTable, addRow, self.voiceStatus, self.editor, self.table]];
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
    self.tocHeight.constant = MIN(self.sections.count, kTocMaxVisibleRows) * kTocRowHeight;
    [self refreshTicks];
    [self refreshControls];
}

- (UIButton *)textButton:(NSString *)title handler:(void (^)(void))handler {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [GLTheme monoDigitFont];
    b.tintColor = [GLTheme accentColor];
    [b addAction:[UIAction actionWithHandler:^(UIAction *a) { handler(); }] forControlEvents:UIControlEventTouchUpInside];
    return b;
}

/// "Start  1:15.0  -0.5 +0.5 Set": nudge by half a second or set to the playhead.
- (UIStackView *)editRowNamed:(NSString *)name value:(UILabel *)value isStart:(BOOL)isStart {
    UILabel *label = [self labelWithFont:[GLTheme bodyFont] color:[GLTheme textSecondaryColor]];
    label.text = name;
    [label setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    __weak typeof(self) weakSelf = self;
    UIButton *minus = [self textButton:@"-0.5" handler:^{ [weakSelf nudgeSelected:isStart by:-kNudgeSeconds]; }];
    UIButton *plus = [self textButton:@"+0.5" handler:^{ [weakSelf nudgeSelected:isStart by:kNudgeSeconds]; }];
    UIButton *set = [self textButton:@"Set" handler:^{ [weakSelf setSelected:isStart to:weakSelf.elapsed]; }];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, value, minus, plus, set]];
    row.spacing = [GLTheme spacingM];
    return row;
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
                                                             usingBlock:^(CMTime time) {
                                                                 [weakSelf recordLoopExtremes];
                                                                 [weakSelf refreshTime];
                                                             }];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.player.currentItem || self.started) return;
    self.started = YES;
    NSDictionary *linked = self.sectionReference
        ? [ClipsSectionsStore sectionForReference:self.sectionReference inSections:self.sections] : nil;
    if (self.sectionReference && !linked) GLLog(@"clips: section reference %@ matches no section", self.sectionReference);
    if (linked) [self selectSection:linked]; else [self play];
    [self runTestHooks];
}

- (void)dealloc {
    [self.player removeTimeObserver:self.timeObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)close {
    [self stopListening];
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
    self.seeksInFlight++;
    [self.player seekToTime:CMTimeMakeWithSeconds(clamped, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero
          completionHandler:^(BOOL finished) { self.seeksInFlight--; }];
    [self refreshTime];
}

- (void)skipBack { [self seekTo:self.elapsed - kSkipSeconds]; }
- (void)skipForward { [self seekTo:self.elapsed + kSkipSeconds]; }

- (void)toggleLoop {
    self.looping = !self.looping;
    [self applyLoopBounds];
    [self refreshControls];
}

#pragma mark - Sections

- (NSDictionary *)sectionWithID:(NSString *)sectionID {
    for (NSDictionary *s in self.sections) if ([s[@"id"] isEqualToString:sectionID]) return s;
    return nil;
}

- (NSDictionary *)selectedSection { return self.selectedSectionID ? [self sectionWithID:self.selectedSectionID] : nil; }

/// The section loop mode confines playback to: the selected one, while loop is on.
- (NSDictionary *)loopSection { return self.looping ? [self selectedSection] : nil; }

- (NSTimeInterval)endOfSection:(NSDictionary *)section {
    NSTimeInterval end = [section[@"end"] doubleValue];
    return self.duration > 0 ? MIN(end, self.duration) : end;
}

/// Confines the player to the looped section (the item stops, and posts the end
/// notification, exactly at its end) and restarts the extremes the sim-test reads.
- (void)applyLoopBounds {
    NSDictionary *section = self.loopSection;
    AVPlayerItem *item = self.player.currentItem;
    self.wraps = 0;
    self.loopEntered = NO;
    self.loopMin = INFINITY;
    self.loopMax = -INFINITY;
    if (!section) {
        item.forwardPlaybackEndTime = kCMTimeInvalid;
        return;
    }
    NSTimeInterval start = [section[@"start"] doubleValue], end = [self endOfSection:section];
    if (self.elapsed < start - 0.05 || self.elapsed >= end) [self seekTo:start];
    item.forwardPlaybackEndTime = CMTimeMakeWithSeconds(end, 600);
}

/// Tapping a section: make it the edit/loop target, jump to its start and play.
- (void)selectSection:(NSDictionary *)section {
    self.selectedSectionID = section[@"id"];
    [self seekTo:[section[@"start"] doubleValue]];
    [self applyLoopBounds];
    [self play];
    [self reloadSections];
}

- (void)reloadSections {
    self.sections = [self.sectionStore sectionsForClip:self.clipID];
    if (self.selectedSectionID && ![self selectedSection]) self.selectedSectionID = nil;
    [self.tocTable reloadData];
    self.tocHeight.constant = MIN(self.sections.count, kTocMaxVisibleRows) * kTocRowHeight;
    [self refreshTicks];
    [self refreshEditor];
}

- (void)toggleEditing {
    self.editToggle.selected = !self.editToggle.selected;
    [self.editToggle setTitle:self.editToggle.selected ? @"Done editing" : @"Edit" forState:UIControlStateNormal];
    if (self.editToggle.selected && !self.selectedSectionID) self.selectedSectionID = self.playingSectionID;
    [self refreshEditor];
}

- (void)renameSelected {
    NSDictionary *section = [self selectedSection];
    if (!section) return;
    [self promptNoteWithTitle:@"Section" text:section[@"name"] action:@"Save" done:^(NSString *text) {
        [self.sectionStore updateSection:section[@"id"] inClip:self.clipID name:text start:nil end:nil];
        [self reloadSections];
    }];
}

- (void)deleteSelected {
    NSDictionary *section = [self selectedSection];
    if (!section) return;
    [self.sectionStore deleteSection:section[@"id"] inClip:self.clipID];
    [self reloadSections];
    [self applyLoopBounds];
}

- (void)refreshTicks {
    NSMutableSet *bounds = [NSMutableSet set];
    for (NSDictionary *s in self.sections) { [bounds addObject:s[@"start"]]; [bounds addObject:s[@"end"]]; }
    self.ticks.boundaries = bounds.allObjects;
    self.ticks.duration = self.duration;
    [self.ticks setNeedsDisplay];
}

/// Section boundaries jump: next = the first section starting after the playhead,
/// previous = the last one that started more than 1.5s ago (restart current first).
- (void)nextSection {
    for (NSDictionary *s in self.sections) {
        if ([s[@"start"] doubleValue] > self.elapsed + 0.05) { [self selectSection:s]; return; }
    }
}

- (void)previousSection {
    for (NSDictionary *s in [self.sections reverseObjectEnumerator]) {
        if ([s[@"start"] doubleValue] < self.elapsed - 1.5) { [self selectSection:s]; return; }
    }
}

- (void)refreshEditor {
    NSDictionary *section = [self selectedSection];
    self.editor.hidden = !(self.editToggle.selected && section);
    self.editName.text = section[@"name"];
    self.startValue.text = section ? SectionTime([section[@"start"] doubleValue]) : @"";
    self.endValue.text = section ? SectionTime([section[@"end"] doubleValue]) : @"";
}

- (void)setSelected:(BOOL)isStart to:(NSTimeInterval)value {
    NSDictionary *section = [self selectedSection];
    if (!section) return;
    NSTimeInterval start = [section[@"start"] doubleValue], end = [section[@"end"] doubleValue];
    NSTimeInterval limit = self.duration > 0 ? self.duration : INFINITY;
    if (isStart) start = MAX(0, MIN(value, end - kMinSectionLength));
    else end = MIN(limit, MAX(value, start + kMinSectionLength));
    [self.sectionStore updateSection:section[@"id"] inClip:self.clipID name:nil start:@(start) end:@(end)];
    [self reloadSections];
    [self applyLoopBounds];
}

- (void)nudgeSelected:(BOOL)isStart by:(NSTimeInterval)delta {
    NSDictionary *section = [self selectedSection];
    if (!section) return;
    [self setSelected:isStart to:[section[isStart ? @"start" : @"end"] doubleValue] + delta];
}

- (void)addSectionHere {
    NSTimeInterval start = self.elapsed, end = start + 10;
    if (self.duration > 0 && end > self.duration) {
        end = self.duration;
        start = MAX(0, end - 10);
    }
    NSDictionary *section = [self.sectionStore addSectionToClip:self.clipID
                                                           name:[NSString stringWithFormat:@"Section %lu", (unsigned long)self.sections.count + 1]
                                                          start:start end:end];
    self.selectedSectionID = section[@"id"];
    [self reloadSections];
    [self applyLoopBounds];
}

/// Fires at the true end of the clip, and, because a looped section sets
/// forwardPlaybackEndTime, exactly at that section's end.
- (void)itemEnded {
    NSDictionary *section = self.loopSection;
    if (section) {
        self.wraps++;
        [self seekTo:[section[@"start"] doubleValue]];
        [self play];
        return;
    }
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
    [self refreshEditor];
    [self refreshTime];
}

/// Only from the periodic observer: right after a seek call, currentTime still
/// holds the old position, which would read as leaving the section.
- (void)recordLoopExtremes {
    if (!self.loopSection || self.seeksInFlight > 0 || self.player.currentItem.status != AVPlayerItemStatusReadyToPlay) return;
    NSDictionary *section = self.loopSection;
    if (!self.loopEntered) {
        // The first seek into the section can lag behind the initial play; only
        // positions after the playhead first reaches the section count.
        if (self.elapsed < [section[@"start"] doubleValue] - 0.05 || self.elapsed > [self endOfSection:section]) return;
        self.loopEntered = YES;
    }
    self.loopMin = MIN(self.loopMin, self.elapsed);
    self.loopMax = MAX(self.loopMax, self.elapsed);
}

- (void)refreshTime {
    if (self.ticks.duration != self.duration) [self refreshTicks];
    self.slider.maximumValue = MAX(self.duration, 1);
    if (!self.scrubbing) {
        self.slider.value = self.elapsed;
        self.elapsedLabel.text = GLFormatDuration(self.elapsed);
    }
    self.totalLabel.text = GLFormatDuration(self.duration);
    NSString *playing = nil;
    for (NSDictionary *s in self.sections) {
        if (self.elapsed >= [s[@"start"] doubleValue] && self.elapsed < [s[@"end"] doubleValue]) { playing = s[@"id"]; break; }
    }
    if (![playing ?: @"" isEqualToString:self.playingSectionID ?: @""]) {
        self.playingSectionID = playing;
        [self.tocTable reloadData];
    }
}

#pragma mark - Voice

/// First tap pauses and listens, a pause in speech or a second tap saves what was said.
- (void)toggleVoice {
    if (self.listener) { [self finishVoice]; return; }
    self.voiceResumes = self.wantsPlay;
    [self pause];
    self.voicePlayhead = self.elapsed;
    self.voiceText = @"";
    self.voiceButton.tintColor = [UIColor systemRedColor];
    [self showVoiceStatus:@"Listening"];
    __weak typeof(self) weakSelf = self;
    self.listener = [[ClipsVoiceListener alloc] init];
    self.listener.onText = ^(NSString *text, BOOL isFinal) { [weakSelf voiceHeard:text isFinal:isFinal]; };
    self.listener.onError = ^(NSString *message) { [weakSelf voiceFailed:message]; };
    [self.listener start];
}

- (void)voiceHeard:(NSString *)text isFinal:(BOOL)isFinal {
    if (!self.listener) return;
    self.voiceText = text;
    [self showVoiceStatus:text];
    [self.voiceSilenceTimer invalidate];
    if (isFinal) { [self finishVoice]; return; }
    __weak typeof(self) weakSelf = self;
    self.voiceSilenceTimer = [NSTimer scheduledTimerWithTimeInterval:kVoiceSilenceSeconds repeats:NO block:^(NSTimer *t) { [weakSelf finishVoice]; }];
}

- (void)voiceFailed:(NSString *)message {
    if (!self.listener) return;
    if (self.voiceText.length) { [self finishVoice]; return; } // keep what was heard before it failed
    [self stopListening];
    [self showVoiceStatus:message];
    if (self.voiceResumes) [self play];
}

- (void)finishVoice {
    if (!self.listener) return;
    [self stopListening];
    [self applyVoiceTranscript:self.voiceText];
    if (self.voiceResumes) [self play];
}

/// Ends capture and gives the audio session back to the player; saves nothing.
- (void)stopListening {
    if (!self.listener) return;
    [self.voiceSilenceTimer invalidate];
    [self.listener stop];
    self.listener = nil;
    self.voiceButton.tintColor = [GLTheme accentColor];
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (![session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:&error] || ![session setActive:YES error:&error]) {
        GLLog(@"clips voice: audio session restore: %@", error);
        [self showVoiceStatus:error.localizedDescription];
    }
}

- (void)showVoiceStatus:(NSString *)text {
    self.voiceStatus.text = text;
    self.voiceStatus.hidden = NO;
}

- (void)applyVoiceTranscript:(NSString *)transcript {
    NSDictionary *command = [ClipsVoiceCommand commandFromTranscript:transcript sections:self.sections playhead:self.voicePlayhead duration:self.duration];
    if (!command) { [self showVoiceStatus:@"Nothing to save"]; return; }
    NSString *kind = command[@"kind"], *label;
    if ([kind isEqualToString:@"note"]) {
        [self.store addNoteToClip:self.clipID time:[command[@"time"] doubleValue] text:command[@"text"]];
        [self reloadNotes];
        label = [NSString stringWithFormat:@"%@ \u00B7 %@", RowTime([command[@"time"] doubleValue]), command[@"text"]];
    } else {
        if ([kind isEqualToString:@"rename"]) {
            [self.sectionStore updateSection:command[@"sectionID"] inClip:self.clipID name:command[@"name"] start:nil end:nil];
        } else {
            if (command[@"truncateID"]) [self.sectionStore updateSection:command[@"truncateID"] inClip:self.clipID name:nil start:nil end:command[@"start"]];
            [self.sectionStore addSectionToClip:self.clipID name:command[@"name"] start:[command[@"start"] doubleValue] end:[command[@"end"] doubleValue]];
        }
        [self reloadSections];
        [self applyLoopBounds];
        label = [NSString stringWithFormat:@"%@ \u00B7 %@", RowTime([command[@"start"] doubleValue]), command[@"name"]];
    }
    [self showVoiceStatus:[command[@"timeIgnored"] boolValue] ? [@"Past the end \u00B7 " stringByAppendingString:label] : label];
}

- (void)openScore {
    ClipScoreViewController *score = [[ClipScoreViewController alloc] initWithFileURL:self.scoreURL];
    [self presentViewController:score animated:YES completion:nil];
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

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return tableView == self.tocTable ? nil : @"Notes";
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    ((UITableViewHeaderFooterView *)view).textLabel.textColor = [GLTheme textSecondaryColor];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return tableView == self.tocTable ? self.sections.count : self.notes.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"row"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"row"];
    cell.backgroundColor = [GLTheme surfaceColor];
    cell.textLabel.font = [GLTheme bodyFont];
    cell.textLabel.textColor = [GLTheme textPrimaryColor];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.font = [UIFont monospacedDigitSystemFontOfSize:[GLTheme bodyFont].pointSize - 1 weight:UIFontWeightRegular];
    cell.detailTextLabel.textColor = [GLTheme textSecondaryColor];
    cell.imageView.image = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    if (tableView == self.tocTable) {
        NSDictionary *section = self.sections[indexPath.row];
        BOOL playing = [section[@"id"] isEqualToString:self.playingSectionID];
        cell.textLabel.text = section[@"name"];
        cell.textLabel.numberOfLines = 1;
        cell.textLabel.textColor = playing ? [GLTheme accentColor] : [GLTheme textPrimaryColor];
        cell.textLabel.font = playing ? [UIFont boldSystemFontOfSize:[GLTheme bodyFont].pointSize] : [GLTheme bodyFont];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\u2013%@", RowTime([section[@"start"] doubleValue]), RowTime([section[@"end"] doubleValue])];
        cell.backgroundColor = playing ? [[GLTheme accentColor] colorWithAlphaComponent:0.2] : [GLTheme surfaceColor];
        return cell;
    }
    NSDictionary *note = self.notes[indexPath.row];
    cell.textLabel.text = note[@"text"];
    cell.detailTextLabel.text = RowTime([note[@"time"] doubleValue]);
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (tableView == self.tocTable) {
        [self selectSection:self.sections[indexPath.row]];
        return;
    }
    [self seekTo:[self.notes[indexPath.row][@"time"] doubleValue]];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL isSection = tableView == self.tocTable;
    NSDictionary *item = isSection ? self.sections[indexPath.row] : self.notes[indexPath.row];
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete"
                                                                       handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        if (isSection) {
            [self.sectionStore deleteSection:item[@"id"] inClip:self.clipID];
            [self reloadSections];
            [self applyLoopBounds];
        } else {
            [self.store deleteNote:item[@"id"] inClip:self.clipID];
            [self reloadNotes];
        }
        done(YES);
    }];
    UIContextualAction *edit = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:isSection ? @"Rename" : @"Edit"
                                                                     handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        NSString *title = isSection ? @"Section" : GLFormatDuration([item[@"time"] doubleValue]);
        [self promptNoteWithTitle:title text:isSection ? item[@"name"] : item[@"text"] action:@"Save" done:^(NSString *text) {
            if (isSection) {
                [self.sectionStore updateSection:item[@"id"] inClip:self.clipID name:text start:nil end:nil];
                [self reloadSections];
            } else {
                [self.store setText:text ofNote:item[@"id"] inClip:self.clipID];
                [self reloadNotes];
            }
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
/// UITEST_CLIPS_LOOP=1 toggles loop, UITEST_CLIPS_SECTION_NUDGE=1 nudges the selected
/// section's start by +0.5s, and UITEST_REPORT_CLIPS=1 logs the result 6 seconds after the player opens.
- (void)runTestHooks {
    NSDictionary *env = [[NSProcessInfo processInfo] environment];
    if (env[@"UITEST_CLIPS_SPEED"]) {
        float target = [env[@"UITEST_CLIPS_SPEED"] floatValue];
        for (int i = 0; i < 10 && fabsf(self.speed - target) > 0.001f; i++) {
            target > self.speed ? [self speedUp] : [self slowDown];
        }
    }
    if ([env[@"UITEST_CLIPS_LOOP"] boolValue] && !self.looping) [self toggleLoop];
    if ([env[@"UITEST_CLIPS_SECTION_NUDGE"] boolValue]) [self nudgeSelected:YES by:kNudgeSeconds];
    if (env[@"UITEST_CLIPS_NOTE"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self addNoteWithText:env[@"UITEST_CLIPS_NOTE"]];
        });
    }
    if (env[@"UITEST_CLIPS_VOICE"]) {
        // Runs what the recognizer would hand over; "|" separates utterances.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            self.voicePlayhead = self.elapsed;
            for (NSString *said in [env[@"UITEST_CLIPS_VOICE"] componentsSeparatedByString:@"|"]) [self applyVoiceTranscript:said];
            NSMutableArray *times = [NSMutableArray array];
            for (NSDictionary *n in self.notes) [times addObject:[NSString stringWithFormat:@"%.0f", [n[@"time"] doubleValue]]];
            NSMutableArray *names = [NSMutableArray array];
            for (NSDictionary *s in self.sections) [names addObject:[NSString stringWithFormat:@"%@@%.0f-%.0f", s[@"name"], [s[@"start"] doubleValue], [s[@"end"] doubleValue]]];
            NSLog(@"UITEST_CLIPS_VOICE noteTimes=%@ sections=%@ status=%@", [times componentsJoinedByString:@","], [names componentsJoinedByString:@","], self.voiceStatus.text);
        });
    }
    if ([env[@"UITEST_CLIPS_SCORE"] boolValue]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (!self.scoreURL) { NSLog(@"UITEST_CLIPS_SCORE none"); return; }
            ClipScoreViewController *score = [[ClipScoreViewController alloc] initWithFileURL:self.scoreURL];
            [self presentViewController:score animated:NO completion:^{ NSLog(@"UITEST_CLIPS_SCORE pages=%ld", (long)score.pageCount); }];
        });
    }
    if ([env[@"UITEST_CLIPS_NEXT"] boolValue]) [self pressNextOnceInSelectedSection:40];
    if (env[@"UITEST_REPORT_CLIPS"]) {
        [self reportClipsAfter:6 attemptsLeft:60];
    }
}

/// Test hook: presses next once the playhead has actually reached the selected section.
- (void)pressNextOnceInSelectedSection:(int)attemptsLeft {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSDictionary *selected = [self selectedSection];
        if (self.seeksInFlight > 0 || self.elapsed < [selected[@"start"] doubleValue] - 0.05) {
            if (attemptsLeft > 0) [self pressNextOnceInSelectedSection:attemptsLeft - 1];
            return;
        }
        NSString *from = self.selectedSectionID;
        [self nextSection];
        NSLog(@"UITEST_CLIPS_NEXT from=%@ to=%@ start=%.2f", from, self.selectedSectionID, [[self selectedSection][@"start"] doubleValue]);
    });
}

/// Logs the state after `delay` seconds; with a section looping it waits (up to
/// attemptsLeft half-seconds) until the loop has wrapped at least once.
- (void)reportClipsAfter:(NSTimeInterval)delay attemptsLeft:(int)attemptsLeft {
    {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.loopSection && self.wraps < 1 && attemptsLeft > 0) {
                [self reportClipsAfter:0.5 attemptsLeft:attemptsLeft - 1];
                return;
            }
            NSDictionary *selected = [self selectedSection];
            NSLog(@"UITEST_CLIPS_REPORT onScreen=%d id=%@ playing=%d rate=%.2f speed=%.2f time=%.2f notes=%lu loop=%d section=%@ start=%.2f end=%.2f min=%.2f max=%.2f wraps=%ld",
                  self.view.window != nil, self.clipID, self.wantsPlay, self.player.rate, self.speed, self.elapsed,
                  (unsigned long)self.notes.count, self.looping, selected[@"id"] ?: @"-",
                  [selected[@"start"] doubleValue], [selected[@"end"] doubleValue],
                  self.loopMin, self.loopMax, (long)self.wraps);
        });
    }
}

@end
