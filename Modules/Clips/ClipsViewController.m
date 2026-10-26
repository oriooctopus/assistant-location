#import "ClipsViewController.h"

#import <AVFoundation/AVFoundation.h>

#import "BakedConfig.h"
#import "ClipsCatalog.h"
#import "GLComponents.h"
#import "GLEndpoints.h"
#import "GLFormat.h"
#import "GLLog.h"
#import "GLTheme.h"

// Manifest and audio files live under Application Support/Clips, fetched from
// the location server (GET /clips/manifest.json, /clips/files/<file>). Every
// file is downloaded as soon as the manifest is known, so a clip plays with no
// connection once the tab has been open online once.
@interface ClipsViewController () <UITableViewDataSource, UITableViewDelegate, AVAudioPlayerDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UIView *emptyView;
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, NSString *> *> *clips;
@property (nonatomic, strong) NSURL *directory;
@property (nonatomic, strong) NSMutableSet<NSString *> *downloading; // clip ids
@property (nonatomic, copy) NSString *pendingID;   // play as soon as known + cached
@property (nonatomic, copy) NSString *playingID;
@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, strong) NSTimer *ticker;
@end

@implementation ClipsViewController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _clips = @[];
        _downloading = [NSMutableSet set];
        NSURL *support = [[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory
                                                                inDomain:NSUserDomainMask
                                                       appropriateForURL:nil
                                                                  create:YES
                                                                   error:nil];
        _directory = [support URLByAppendingPathComponent:@"Clips" isDirectory:YES];
        NSError *error = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtURL:_directory
                                      withIntermediateDirectories:YES attributes:nil error:&error]) {
            [NSException raise:NSInternalInconsistencyException format:@"Clips: cannot create %@: %@", _directory, error];
        }
    }
    return self;
}

#pragma mark - View

- (void)viewDidLoad {
    [super viewDidLoad];
    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.dataSource = self;
    self.table.delegate = self;
    [self.view addSubview:self.table];
    self.emptyView = [GLComponents emptyStateViewWithMessage:@"No clips"];
    [self.view addSubview:self.emptyView];
    [NSLayoutConstraint activateConstraints:@[
        [self.emptyView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.emptyView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [self.emptyView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.emptyView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
    self.emptyView.hidden = self.clips.count > 0;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applyTheme)
                                                 name:GLThemeDidChangeNotification object:nil];
    [self applyTheme];

    [self loadCachedManifest];
    [self refreshManifest];
}

- (void)dealloc {
    [self.ticker invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)applyTheme {
    self.view.backgroundColor = [GLTheme backgroundColor];
    self.table.backgroundColor = [UIColor clearColor];
    self.table.separatorColor = [GLTheme textSecondaryColor];
    [self.table reloadData];
}

- (void)setClips:(NSArray<NSDictionary<NSString *, NSString *> *> *)clips {
    _clips = [clips copy];
    if (self.isViewLoaded) {
        self.emptyView.hidden = clips.count > 0;
        [self.table reloadData];
    }
}

#pragma mark - Manifest and files

- (NSURL *)manifestCacheURL {
    return [self.directory URLByAppendingPathComponent:@"manifest.json"];
}

- (NSURL *)fileURLForClip:(NSDictionary *)clip {
    return [ClipsCatalog localURLForFile:clip[@"file"] inDirectory:self.directory];
}

- (BOOL)isCached:(NSDictionary *)clip {
    return [[NSFileManager defaultManager] fileExistsAtPath:[self fileURLForClip:clip].path];
}

- (NSDictionary *)clipWithID:(NSString *)clipID {
    for (NSDictionary *clip in self.clips) {
        if ([clip[@"id"] isEqualToString:clipID]) return clip;
    }
    return nil;
}

- (void)loadCachedManifest {
    NSData *data = [NSData dataWithContentsOfURL:[self manifestCacheURL]];
    if (!data) return;
    NSError *error = nil;
    NSArray *clips = [ClipsCatalog clipsFromManifestData:data error:&error];
    if (!clips) {
        [NSException raise:NSInternalInconsistencyException format:@"Clips: cached manifest is invalid: %@", error.localizedDescription];
    }
    self.clips = clips;
}

/// nil when this build has no server to talk to (CI builds bake no host);
/// UITEST_CLIPS_BASE_URL points the tab at sim-test's mock server.
- (NSURL *)endpointForPath:(NSString *)path {
    NSString *override = [[NSProcessInfo processInfo] environment][@"UITEST_CLIPS_BASE_URL"];
    if (override.length) return [NSURL URLWithString:path relativeToURL:[NSURL URLWithString:override]];
    if (GL_BAKED_HOST.length == 0 || [GL_BAKED_HOST isEqualToString:@"NO_HOST_BAKED_IN"]) return nil;
    return GLEndpointURL(path);
}

- (NSURLRequest *)requestForPath:(NSString *)path {
    NSURL *url = [self endpointForPath:path];
    if (!url) return nil;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 30;
    [request setValue:[NSString stringWithFormat:@"Bearer %@", GL_BAKED_TOKEN] forHTTPHeaderField:@"Authorization"];
    return request;
}

- (void)refreshManifest {
    NSURLRequest *request = [self requestForPath:@"/clips/manifest.json"];
    if (!request) {
        GLLog(@"no server baked into this build, manifest not refreshed");
        return;
    }
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            GLLog(@"manifest fetch failed (offline copy stays): %@", error.localizedDescription);
            return;
        }
        NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
        if (status != 200) {
            GLLog(@"manifest fetch got HTTP %ld", (long)status);
            return;
        }
        NSError *parseError = nil;
        NSArray *clips = [ClipsCatalog clipsFromManifestData:data error:&parseError];
        if (!clips) {
            GLLog(@"%@", parseError.localizedDescription);
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [data writeToURL:[self manifestCacheURL] atomically:YES];
            self.clips = clips;
            for (NSDictionary *clip in clips) [self downloadClip:clip];
            [self startPendingIfReady];
        });
    }] resume];
}

- (void)downloadClip:(NSDictionary *)clip {
    NSString *clipID = clip[@"id"];
    if ([self isCached:clip] || [self.downloading containsObject:clipID]) return;
    NSURLRequest *request = [self requestForPath:[@"/clips/files/" stringByAppendingString:clip[@"file"]]];
    if (!request) return;
    [self.downloading addObject:clipID];
    [self reloadRowForClipID:clipID];
    [[[NSURLSession sharedSession] downloadTaskWithRequest:request completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
        NSError *moveError = nil;
        if (!error && status == 200) {
            // The temp file is deleted when this block returns, so move it now.
            NSURL *dest = [self fileURLForClip:clip];
            [[NSFileManager defaultManager] removeItemAtURL:dest error:nil];
            [[NSFileManager defaultManager] moveItemAtURL:location toURL:dest error:&moveError];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.downloading removeObject:clipID];
            if (error || status != 200 || moveError) {
                GLLog(@"download of %@ failed: %@ (HTTP %ld)", clipID,
                      (error ?: moveError).localizedDescription ?: @"-", (long)status);
                if ([self.pendingID isEqualToString:clipID]) self.pendingID = nil;
            }
            [self reloadRowForClipID:clipID];
            [self startPendingIfReady];
        });
    }] resume];
}

#pragma mark - Playback

- (void)playClipWithID:(NSString *)clipID {
    [self loadViewIfNeeded];
    self.pendingID = clipID;
    NSDictionary *clip = [self clipWithID:clipID];
    if (clip) [self downloadClip:clip];
    [self startPendingIfReady];
}

- (void)startPendingIfReady {
    if (!self.pendingID) return;
    NSDictionary *clip = [self clipWithID:self.pendingID];
    if (!clip || ![self isCached:clip]) return;
    self.pendingID = nil;
    [self startClip:clip];
}

- (void)startClip:(NSDictionary *)clip {
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (![session setCategory:AVAudioSessionCategoryPlayback error:&error] || ![session setActive:YES error:&error]) {
        [NSException raise:NSInternalInconsistencyException format:@"Clips: audio session: %@", error];
    }
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:[self fileURLForClip:clip] error:&error];
    if (!player) {
        [NSException raise:NSInternalInconsistencyException format:@"Clips: cannot open %@: %@", clip[@"file"], error];
    }
    NSString *previous = self.playingID;
    player.delegate = self;
    self.player = player;
    self.playingID = clip[@"id"];
    BOOL started = [player play];
    GLLog(@"playing id=%@ started=%d duration=%.1f", clip[@"id"], started, player.duration);
    [self reloadRowForClipID:previous];
    [self reloadRowForClipID:self.playingID];
    [self.ticker invalidate];
    self.ticker = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    if ([[NSProcessInfo processInfo] environment][@"UITEST_REPORT_CLIPS"]) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            ClipsViewController *s = weakSelf;
            NSLog(@"UITEST_CLIPS_REPORT onScreen=%d id=%@ playing=%d time=%.2f", s.view.window != nil,
                  s.playingID ?: @"-", s.player.isPlaying, s.player.currentTime);
        });
    }
}

- (void)stopPlayback {
    NSString *previous = self.playingID;
    [self.player stop];
    self.player = nil;
    self.playingID = nil;
    [self.ticker invalidate];
    self.ticker = nil;
    [self reloadRowForClipID:previous];
}

- (void)tick {
    [self reloadRowForClipID:self.playingID];
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    if (player == self.player) [self stopPlayback];
}

#pragma mark - Table

- (void)reloadRowForClipID:(NSString *)clipID {
    if (!clipID || !self.isViewLoaded) return;
    for (NSUInteger i = 0; i < self.clips.count; i++) {
        if ([self.clips[i][@"id"] isEqualToString:clipID]) {
            [self.table reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:i inSection:0]]
                              withRowAnimation:UITableViewRowAnimationNone];
        }
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.clips.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"clip"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"clip"];
    NSDictionary *clip = self.clips[indexPath.row];
    NSString *clipID = clip[@"id"];
    BOOL playing = [self.playingID isEqualToString:clipID] && self.player.isPlaying;
    BOOL current = [self.playingID isEqualToString:clipID];

    cell.backgroundColor = [GLTheme surfaceColor];
    cell.textLabel.text = clip[@"title"];
    cell.textLabel.font = [GLTheme bodyFont];
    cell.textLabel.textColor = [GLTheme textPrimaryColor];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.font = [GLTheme monoDigitFont];
    cell.detailTextLabel.textColor = [GLTheme textSecondaryColor];
    cell.detailTextLabel.text = current
        ? [NSString stringWithFormat:@"%@ / %@", GLFormatDuration(self.player.currentTime), GLFormatDuration(self.player.duration)]
        : nil;

    NSString *symbol = playing ? @"pause.fill" : ([self isCached:clip] ? @"play.fill" : @"arrow.down.circle");
    cell.imageView.image = [UIImage systemImageNamed:symbol];
    cell.imageView.tintColor = [GLTheme accentColor];
    if ([self.downloading containsObject:clipID]) {
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        cell.accessoryView = spinner;
    } else {
        cell.accessoryView = nil;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *clip = self.clips[indexPath.row];
    if ([self.playingID isEqualToString:clip[@"id"]]) {
        if (self.player.isPlaying) [self.player pause]; else [self.player play];
        [self reloadRowForClipID:clip[@"id"]];
        return;
    }
    [self playClipWithID:clip[@"id"]];
}

@end
