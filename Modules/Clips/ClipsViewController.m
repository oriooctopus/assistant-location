#import "ClipsViewController.h"

#import "BakedConfig.h"
#import "ClipPlayerViewController.h"
#import "ClipsCatalog.h"
#import "ClipsNotesStore.h"
#import "ClipsSectionsStore.h"
#import "ClipsTakesStore.h"
#import "GLComponents.h"
#import "GLDurableOutbox.h"
#import "GLEndpoints.h"
#import "GLLog.h"
#import "GLTheme.h"

// Manifest and audio files live under Application Support/Clips, fetched from
// the location server (GET /clips/manifest.json, /clips/files/<file>). Every
// file is downloaded as soon as the manifest is known, so a clip plays with no
// connection once the tab has been open online once.
@interface ClipsViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UIView *emptyView;
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, NSString *> *> *clips;
@property (nonatomic, strong) NSURL *directory;
@property (nonatomic, strong) NSMutableSet<NSString *> *downloading; // clip ids
@property (nonatomic, copy) NSString *pendingID;   // open the player as soon as known + cached + on screen
@property (nonatomic, copy) NSString *pendingSection; // section reference for pendingID
@property (nonatomic, strong) ClipsNotesStore *notes;
@property (nonatomic, strong) ClipsSectionsStore *sections;
@property (nonatomic, strong) ClipsTakesStore *takes;
@property (nonatomic, strong) NSMutableSet<NSString *> *sectionsSettled; // clip ids whose section pull finished, either way
@property (nonatomic, strong) GLDurableOutbox *outbox; // created on first use
@end

@implementation ClipsViewController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _clips = @[];
        _downloading = [NSMutableSet set];
        _sectionsSettled = [NSMutableSet set];
        NSURL *support = [[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory
                                                                inDomain:NSUserDomainMask
                                                       appropriateForURL:nil
                                                                  create:YES
                                                                   error:nil];
        _directory = [support URLByAppendingPathComponent:@"Clips" isDirectory:YES];
        __weak typeof(self) weakSelf = self;
        _notes = [[ClipsNotesStore alloc] initWithDirectory:_directory outbox:^GLDurableOutbox *{ return [weakSelf notesOutbox]; }];
        _sections = [[ClipsSectionsStore alloc] initWithDirectory:_directory outbox:^GLDurableOutbox *{ return [weakSelf notesOutbox]; }];
        _takes = [[ClipsTakesStore alloc] initWithDirectory:_directory outbox:^GLDurableOutbox *{ return [weakSelf notesOutbox]; }];
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

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self openPendingIfReady];
}

- (void)dealloc {
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

/// The notes queue: its own outbox directory, pointed at the same server as the
/// manifest. nil when this build has no server (nothing to sync to).
- (GLDurableOutbox *)notesOutbox {
    if (!self.outbox && [self endpointForPath:@"/"]) {
        NSURL *dir = [self.directory URLByAppendingPathComponent:@"Outbox" isDirectory:YES];
        __weak typeof(self) weakSelf = self;
        self.outbox = [[GLDurableOutbox alloc] initWithDirectory:dir
                                                      urlBuilder:^NSURL *(NSString *path) { return [weakSelf endpointForPath:path]; }
                                                           token:GL_BAKED_TOKEN
                                            sessionConfiguration:nil];
        [self.outbox startDraining];
    }
    return self.outbox;
}

- (void)pullNotesForClip:(NSDictionary *)clip {
    NSString *clipID = clip[@"id"];
    NSURLRequest *request = [self requestForPath:[NSString stringWithFormat:@"/clips/%@/notes", clipID]];
    if (!request) return;
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || ((NSHTTPURLResponse *)response).statusCode != 200) {
            GLLog(@"notes pull for %@ failed: %@", clipID, error.localizedDescription ?: @"HTTP error");
            return;
        }
        NSArray *notes = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![notes isKindOfClass:[NSArray class]]) {
            GLLog(@"notes pull for %@ returned a non-array", clipID);
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ [self.notes adoptServerNotes:notes forClip:clipID]; });
    }] resume];
}

- (void)pullSectionsForClip:(NSDictionary *)clip {
    NSString *clipID = clip[@"id"];
    NSURLRequest *request = [self requestForPath:[NSString stringWithFormat:@"/clips/%@/sections", clipID]];
    if (!request) {
        [self.sectionsSettled addObject:clipID];
        return;
    }
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSArray *sections = nil;
        if (error || ((NSHTTPURLResponse *)response).statusCode != 200) {
            GLLog(@"sections pull for %@ failed: %@", clipID, error.localizedDescription ?: @"HTTP error");
        } else {
            sections = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![sections isKindOfClass:[NSArray class]]) {
                GLLog(@"sections pull for %@ returned a non-array", clipID);
                sections = nil;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (sections) [self.sections adoptServerSections:sections forClip:clipID];
            [self.sectionsSettled addObject:clipID];
            [self openPendingIfReady];
        });
    }] resume];
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
            for (NSDictionary *clip in clips) {
                [self downloadClip:clip];
                [self pullNotesForClip:clip];
                [self pullSectionsForClip:clip];
            }
            [self openPendingIfReady];
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
            [self openPendingIfReady];
        });
    }] resume];
}

#pragma mark - Player

/// Opens the player for this clip: right away when it is known, cached and the
/// tab is on screen, otherwise as soon as all three are true.
- (void)playClipWithID:(NSString *)clipID {
    [self playClipWithID:clipID sectionReference:nil];
}

- (void)playClipWithID:(NSString *)clipID sectionReference:(NSString *)sectionReference {
    [self loadViewIfNeeded];
    self.pendingID = clipID;
    self.pendingSection = sectionReference;
    NSDictionary *clip = [self clipWithID:clipID];
    if (clip) [self downloadClip:clip];
    [self openPendingIfReady];
}

- (BOOL)sectionsForClipAreEmpty:(NSString *)clipID {
    return [self.sections sectionsForClip:clipID].count == 0;
}

- (void)openPendingIfReady {
    if (!self.pendingID || !self.view.window) return;
    NSDictionary *clip = [self clipWithID:self.pendingID];
    if (!clip || ![self isCached:clip]) return;
    // A section link needs the section list: wait for the pull (it settles on failure too, so offline still opens).
    if (self.pendingSection && ![self.sectionsSettled containsObject:self.pendingID]
        && [self sectionsForClipAreEmpty:self.pendingID]) return;
    self.pendingID = nil;
    NSString *sectionReference = self.pendingSection;
    self.pendingSection = nil;
    ClipPlayerViewController *player = [[ClipPlayerViewController alloc] initWithClipID:clip[@"id"]
                                                                                  title:clip[@"title"]
                                                                                fileURL:[self fileURLForClip:clip]
                                                                                  notes:self.notes
                                                                               sections:self.sections
                                                                                  takes:self.takes
                                                                       sectionReference:sectionReference];
    player.modalPresentationStyle = UIModalPresentationFullScreen;
    if (self.presentedViewController) {
        [self dismissViewControllerAnimated:NO completion:nil];
    }
    [self presentViewController:player animated:NO completion:nil];
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
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"clip"];
    NSDictionary *clip = self.clips[indexPath.row];
    cell.backgroundColor = [GLTheme surfaceColor];
    cell.textLabel.text = clip[@"title"];
    cell.textLabel.font = [GLTheme bodyFont];
    cell.textLabel.textColor = [GLTheme textPrimaryColor];
    cell.textLabel.numberOfLines = 0;
    cell.imageView.image = [UIImage systemImageNamed:[self isCached:clip] ? @"play.fill" : @"arrow.down.circle"];
    cell.imageView.tintColor = [GLTheme accentColor];
    if ([self.downloading containsObject:clip[@"id"]]) {
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
    [self playClipWithID:self.clips[indexPath.row][@"id"]];
}

@end
