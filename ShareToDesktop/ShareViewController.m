#import "ShareViewController.h"
#import "ShareConfig.h"
#import "../Shared/GLDropUploader.h"

#import <ImageIO/ImageIO.h>

// Share-sheet extension with two independent actions on the same shared
// items:
//
// 1. The original /drop auto-upload: starts the moment the sheet appears,
//    POSTs the raw bytes of every image/video to the Linux box's location
//    server. No compose field, nothing to configure.
// 2. "Start conversation": POSTs just the IMAGE items (JPEG/PNG re-encoded
//    where needed) to /sessions/upload, then opens the containing app
//    straight into a new session with those images pre-attached.
//
// Both share the same NSItemProvider list; (2) is a strict subset (images
// only, capped lower) uploaded to a different endpoint with a different
// response shape (JSON {id}, not empty-body-on-success), so it gets its own
// upload path rather than reusing GLDropUploader's file-staging one, which
// is built around /drop's contract.
//
// -completeRequestReturningItems: is called from exactly two places: after
// ALL /drop uploads finish (via the "Done" button, since dismissing before
// every item lands kills the upload mid-flight) or after the containing app
// has actually been asked to open (in the -openContainingAppURL:completion:
// completion handler) -- never eagerly, and never on a fixed timer.

static NSString *const kImageType = @"public.image";
static const NSUInteger kMaxItems = 10;
static const NSUInteger kMaxConversationItems = 5;

// Downsample target for "Start conversation" uploads -- see
// -downsampledJPEGDataAtURL: below. A share extension gets a far smaller
// memory allowance than a normal app (measured ~120MB before jetsam); a
// modern phone camera photo decodes to ~190MB as a full-res UIImage before
// it's even re-encoded, so decoding full-res and THEN downsizing is already
// too late. This also keeps every upload well under the server's 15MB cap.
static const CGFloat kAttachmentMaxPixelSize = 2048;
static const CGFloat kAttachmentJPEGQuality = 0.85;

// Mirrors SessionsModule.m's kAttachIDPattern exactly (App target and
// Extension target compile separately, so this can't just be shared via
// import) -- validated again here, on what the server handed back, before
// it goes into a URL the containing app will parse. A malformed id reaching
// -openSessionWithAttachmentIDs: would build a URL SessionsModule silently
// drops the id from anyway, but failing loudly HERE means the user sees why
// instead of "opened, but my image wasn't there."
static NSString *const kAttachIDPattern =
    @"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\.(png|jpg|gif|webp)$";

// Fire-and-forget line into the box's location-server log (GET /debug-log,
// printed as "[JOURNAL DEBUG] ..."). The app-opening step can't be exercised
// in CI, so this is the only record of what it did on a real phone.
static void GLShareDebugLog(NSString *msg) {
  NSString *encoded = [msg stringByAddingPercentEncodingWithAllowedCharacters:
                               NSCharacterSet.alphanumericCharacterSet];
  NSURL *url = [NSURL URLWithString:
      [NSString stringWithFormat:@"http://%@:8302/debug-log?msg=%@", GLDropHost, encoded]];
  if (!url) return;
  [[[NSURLSession sharedSession] dataTaskWithURL:url] resume];
}

@interface ShareViewController ()
@property(nonatomic, strong) NSArray<NSItemProvider *> *providers;
@property(nonatomic, strong) NSArray<NSItemProvider *> *imageProviders;
@property(nonatomic, strong) NSMutableArray<UILabel *> *rowLabels;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIButton *retryButton;
@property(nonatomic, strong) UIButton *doneButton;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic, assign) BOOL started;
// Set once the /drop dispatch_group has settled -- success OR failure,
// "attempted and done" not "succeeded". Distinct from dropUploadsDone below
// (kept for the Done-button UI, success only) so a concurrent "Start
// conversation" completion knows whether it's safe to end the extension
// yet: ending it kills any /drop NSURLSessionTask still in flight, since
// they share this same process.
@property(nonatomic, assign) BOOL dropUploadAttemptFinished;
@property(nonatomic, assign) BOOL dropUploadsDone;
// Set when "Start conversation" finished (opened the app) before /drop's
// attempt had settled -- tells the /drop completion to finish the
// extension request once IT settles, instead of just showing Done/Retry.
@property(nonatomic, assign) BOOL completePendingDropFinish;

@property(nonatomic, strong) UIButton *startConversationButton;
@property(nonatomic, strong) UILabel *conversationStatusLabel;
@property(nonatomic, strong) UIButton *conversationRetryButton;
@property(nonatomic, assign) BOOL conversationInFlight;
@end

@implementation ShareViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  self.providers = [self collectProviders];
  self.imageProviders = [self collectImageProviders];
  [self buildUI];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  if (self.started) return;
  self.started = YES;
  [self startUploads];
}

/// The share sheet can hand over several extension items, each with several
/// attachments; flatten them and keep everything GLDropUploader can stage
/// (images, videos, audio recordings, plain files), capped at kMaxItems.
- (NSArray<NSItemProvider *> *)collectProviders {
  NSMutableArray<NSItemProvider *> *out = [NSMutableArray array];
  for (NSExtensionItem *item in self.extensionContext.inputItems) {
    for (NSItemProvider *provider in item.attachments) {
      if ([GLDropUploader providerIsSupported:provider] && out.count < kMaxItems) {
        [out addObject:provider];
      }
    }
  }
  return out;
}

/// Subset of -collectProviders: images only (no video — session.html's
/// attachment strip is images-only), capped lower than the /drop list since
/// these get embedded inline in the chat rather than just dropped to disk.
- (NSArray<NSItemProvider *> *)collectImageProviders {
  NSMutableArray<NSItemProvider *> *out = [NSMutableArray array];
  for (NSItemProvider *provider in self.providers) {
    if ([provider hasItemConformingToTypeIdentifier:kImageType] &&
        out.count < kMaxConversationItems) {
      [out addObject:provider];
    }
  }
  return out;
}

#pragma mark - UI

- (void)buildUI {
  UILabel *title = [[UILabel alloc] init];
  title.text = @"Share to desktop";
  title.font = [UIFont boldSystemFontOfSize:18];
  title.textAlignment = NSTextAlignmentCenter;

  self.spinner = [[UIActivityIndicatorView alloc]
      initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
  [self.spinner startAnimating];

  self.statusLabel = [[UILabel alloc] init];
  self.statusLabel.font = [UIFont systemFontOfSize:13];
  self.statusLabel.textColor = UIColor.secondaryLabelColor;
  self.statusLabel.textAlignment = NSTextAlignmentCenter;
  self.statusLabel.numberOfLines = 0;
  self.statusLabel.text = [NSString stringWithFormat:@"%lu item%@",
                                                     (unsigned long)self.providers.count,
                                                     self.providers.count == 1 ? @"" : @"s"];

  UIStackView *rows = [[UIStackView alloc] init];
  rows.axis = UILayoutConstraintAxisVertical;
  rows.spacing = 4;
  self.rowLabels = [NSMutableArray array];
  for (NSUInteger i = 0; i < self.providers.count; i++) {
    UILabel *row = [[UILabel alloc] init];
    row.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    row.lineBreakMode = NSLineBreakByTruncatingMiddle;
    row.text = [NSString stringWithFormat:@"%lu. waiting…", (unsigned long)(i + 1)];
    [self.rowLabels addObject:row];
    [rows addArrangedSubview:row];
  }

  self.retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
  [self.retryButton setTitle:@"Retry" forState:UIControlStateNormal];
  [self.retryButton addTarget:self
                       action:@selector(retryTapped)
             forControlEvents:UIControlEventTouchUpInside];
  self.retryButton.hidden = YES;

  self.doneButton = [UIButton buttonWithType:UIButtonTypeSystem];
  [self.doneButton setTitle:@"Done" forState:UIControlStateNormal];
  self.doneButton.titleLabel.font = [UIFont boldSystemFontOfSize:15];
  [self.doneButton addTarget:self
                       action:@selector(doneTapped)
             forControlEvents:UIControlEventTouchUpInside];
  self.doneButton.hidden = YES;

  UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
  [cancel setTitle:@"Cancel" forState:UIControlStateNormal];
  [cancel addTarget:self
                action:@selector(cancelTapped)
      forControlEvents:UIControlEventTouchUpInside];

  UIStackView *buttons = [[UIStackView alloc]
      initWithArrangedSubviews:@[ cancel, self.retryButton, self.doneButton ]];
  buttons.axis = UILayoutConstraintAxisHorizontal;
  buttons.spacing = 24;
  buttons.distribution = UIStackViewDistributionFillEqually;

  // "Start conversation" section -- independent of the /drop upload above,
  // visible (though maybe disabled) from first paint.
  self.startConversationButton = [UIButton buttonWithType:UIButtonTypeSystem];
  [self.startConversationButton setTitle:@"Start conversation" forState:UIControlStateNormal];
  self.startConversationButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
  [self.startConversationButton addTarget:self
                                    action:@selector(startConversationTapped)
                          forControlEvents:UIControlEventTouchUpInside];
  self.startConversationButton.enabled = self.imageProviders.count > 0;

  self.conversationStatusLabel = [[UILabel alloc] init];
  self.conversationStatusLabel.font = [UIFont systemFontOfSize:13];
  self.conversationStatusLabel.textColor = UIColor.secondaryLabelColor;
  self.conversationStatusLabel.textAlignment = NSTextAlignmentCenter;
  self.conversationStatusLabel.numberOfLines = 0;
  self.conversationStatusLabel.hidden = YES;

  self.conversationRetryButton = [UIButton buttonWithType:UIButtonTypeSystem];
  [self.conversationRetryButton setTitle:@"Retry" forState:UIControlStateNormal];
  [self.conversationRetryButton addTarget:self
                                    action:@selector(startConversationTapped)
                          forControlEvents:UIControlEventTouchUpInside];
  self.conversationRetryButton.hidden = YES;

  UIStackView *conversationStack = [[UIStackView alloc] initWithArrangedSubviews:@[
    self.startConversationButton, self.conversationStatusLabel, self.conversationRetryButton
  ]];
  conversationStack.axis = UILayoutConstraintAxisVertical;
  conversationStack.spacing = 6;

  UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
    title, self.spinner, self.statusLabel, rows, buttons, conversationStack
  ]];
  stack.axis = UILayoutConstraintAxisVertical;
  stack.spacing = 12;
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:stack];

  UILayoutGuide *guide = self.view.layoutMarginsGuide;
  [NSLayoutConstraint activateConstraints:@[
    [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    [stack.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:16],
    [stack.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-16],
  ]];
}

- (void)setRow:(NSUInteger)index text:(NSString *)text {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (index < self.rowLabels.count) {
      self.rowLabels[index].text = [NSString stringWithFormat:@"%lu. %@", (unsigned long)(index + 1), text];
    }
  });
}

- (void)showFailure:(NSString *)message {
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.spinner stopAnimating];
    self.spinner.hidden = YES;
    self.statusLabel.textColor = UIColor.systemRedColor;
    self.statusLabel.text = message;
    self.retryButton.hidden = NO;
  });
}

- (void)retryTapped {
  self.retryButton.hidden = YES;
  self.spinner.hidden = NO;
  [self.spinner startAnimating];
  self.statusLabel.textColor = UIColor.secondaryLabelColor;
  self.statusLabel.text = @"Retrying…";
  self.dropUploadAttemptFinished = NO;
  [self startUploads];
}

// Marks the /drop attempt settled (success or failure) and, if a
// Start-conversation completion is waiting on it, finishes the extension
// request now -- see completePendingDropFinish's doc comment.
- (void)markDropAttemptFinished {
  self.dropUploadAttemptFinished = YES;
  if (self.completePendingDropFinish) {
    self.completePendingDropFinish = NO;
    [self.extensionContext completeRequestReturningItems:@[] completionHandler:nil];
  }
}

- (void)doneTapped {
  [self.extensionContext completeRequestReturningItems:@[] completionHandler:nil];
}

- (void)cancelTapped {
  [self.extensionContext cancelRequestWithError:[NSError errorWithDomain:@"ShareToDesktop"
                                                                    code:1
                                                                userInfo:nil]];
}

#pragma mark - Upload (/drop, auto-started)

- (void)startUploads {
  if (self.providers.count == 0) {
    [self showFailure:@"Nothing to upload — nothing shareable as a file was shared."];
    [self markDropAttemptFinished];
    return;
  }
  if ([GLDropToken isEqualToString:@"NO_TOKEN_BAKED_IN"]) {
    [self showFailure:@"No token baked in — this build cannot upload."];
    [self markDropAttemptFinished];
    return;
  }
  if ([GLDropHost isEqualToString:@"NO_HOST_BAKED_IN"]) {
    [self showFailure:@"No host baked in — this build cannot upload."];
    [self markDropAttemptFinished];
    return;
  }

  __block NSString *firstError = nil;
  dispatch_group_t group = dispatch_group_create();

  [self.providers enumerateObjectsUsingBlock:^(NSItemProvider *provider, NSUInteger idx, BOOL *stop) {
    dispatch_group_enter(group);
    [self setRow:idx text:@"loading…"];
    [GLDropUploader loadItemFromProvider:provider
                  index:idx
             completion:^(NSURL *fileURL, NSString *filename, NSString *contentType, NSString *error) {
               if (!fileURL) {
                 [self setRow:idx text:[NSString stringWithFormat:@"failed — %@", error]];
                 if (!firstError) firstError = error;
                 dispatch_group_leave(group);
                 return;
               }
               [self setRow:idx text:[NSString stringWithFormat:@"%@ — uploading…", filename]];
               [GLDropUploader uploadFileAtURL:fileURL
                       filename:filename
                    contentType:contentType
                     toEndpoint:[NSString stringWithFormat:@"http://%@:8302/drop", GLDropHost]
                          token:GLDropToken
                     completion:^(NSString *uploadError) {
                       if (uploadError) {
                         [self setRow:idx text:[NSString stringWithFormat:@"%@ — failed", filename]];
                         if (!firstError) firstError = uploadError;
                       } else {
                         [self setRow:idx text:[NSString stringWithFormat:@"%@ — Uploaded ✓", filename]];
                       }
                       dispatch_group_leave(group);
                     }];
             }];
  }];

  dispatch_group_notify(group, dispatch_get_main_queue(), ^{
    // Mark BEFORE the early-return-on-failure below: a completePendingDropFinish
    // waiter needs to hear "the group settled" regardless of outcome, and
    // -markDropAttemptFinished is what clears that flag and finishes the
    // extension request if so.
    BOOL wasPendingCompletion = self.completePendingDropFinish;
    [self markDropAttemptFinished];
    if (wasPendingCompletion) return;

    if (firstError) {
      [self showFailure:firstError];
      return;
    }
    [self.spinner stopAnimating];
    self.spinner.hidden = YES;
    self.statusLabel.text = @"Uploaded ✓";
    self.dropUploadsDone = YES;
    // No auto-dismiss: completing the request early kills anything still in
    // flight elsewhere in the extension (e.g. a "Start conversation" upload
    // the user kicked off in parallel), so the user drives the exit instead.
    self.doneButton.hidden = NO;
  });
}

#pragma mark - "Start conversation"

- (void)startConversationTapped {
  if (self.conversationInFlight) return;
  if (self.imageProviders.count == 0) return;
  if ([GLDropToken isEqualToString:@"NO_TOKEN_BAKED_IN"] ||
      [GLDropHost isEqualToString:@"NO_HOST_BAKED_IN"]) {
    [self showConversationFailure:@"No host/token baked in — this build cannot upload."];
    return;
  }

  self.conversationInFlight = YES;
  self.startConversationButton.enabled = NO;
  self.conversationRetryButton.hidden = YES;
  self.conversationStatusLabel.hidden = NO;
  self.conversationStatusLabel.textColor = UIColor.secondaryLabelColor;

  // Serial, one image at a time -- NOT enumerateObjectsUsingBlock: kicking
  // off all 5 loads/uploads concurrently. Each load decodes a full image
  // (see -downsampledJPEGDataAtURL:) and, alongside the concurrent /drop
  // uploads already running, five decodes in flight at once is what was
  // blowing the extension's jetsam limit.
  [self uploadConversationImageAtIndex:0
                                  total:self.imageProviders.count
                            uploadedIDs:[NSMutableArray arrayWithCapacity:self.imageProviders.count]];
}

- (void)uploadConversationImageAtIndex:(NSUInteger)index
                                  total:(NSUInteger)total
                            uploadedIDs:(NSMutableArray<NSString *> *)uploadedIDs {
  if (index == total) {
    self.conversationStatusLabel.textColor = UIColor.secondaryLabelColor;
    self.conversationStatusLabel.text = @"Opening…";
    [self openSessionWithAttachmentIDs:uploadedIDs];
    return;
  }

  self.conversationStatusLabel.text =
      [NSString stringWithFormat:@"Uploading %lu/%lu…", (unsigned long)(index + 1), (unsigned long)total];

  NSItemProvider *provider = self.imageProviders[index];
  __weak __typeof(self) weakSelf = self;
  [self loadSessionImageDataFromProvider:provider
                               completion:^(NSData *data, NSString *contentType, NSString *loadError) {
    __typeof(self) strongSelf = weakSelf;
    if (!strongSelf) return;
    if (!data) {
      strongSelf.conversationInFlight = NO;
      [strongSelf showConversationFailure:loadError ?: @"could not read image"];
      return;
    }
    [strongSelf uploadSessionImageData:data
                             contentType:contentType
                              completion:^(NSString *uploadedID, NSString *uploadError) {
      dispatch_async(dispatch_get_main_queue(), ^{
        __typeof(self) strongSelf2 = weakSelf;
        if (!strongSelf2) return;
        // Never proceed with a missing OR malformed id: a bad id reaching
        // -openSessionWithAttachmentIDs: would silently drop the image the
        // user picked (SessionsModule.m filters it out on the app side)
        // with no way for them to notice -- fail loudly here instead.
        if (!uploadedID || ![strongSelf2 isValidAttachmentID:uploadedID]) {
          strongSelf2.conversationInFlight = NO;
          NSString *message = uploadedID ? @"server returned an invalid attachment id"
                                          : (uploadError ?: @"upload failed");
          [strongSelf2 showConversationFailure:message];
          return;
        }
        [uploadedIDs addObject:uploadedID];
        [strongSelf2 uploadConversationImageAtIndex:index + 1 total:total uploadedIDs:uploadedIDs];
      });
    }];
  }];
}

- (BOOL)isValidAttachmentID:(NSString *)uploadedID {
  static NSRegularExpression *idRegex;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    idRegex = [NSRegularExpression regularExpressionWithPattern:kAttachIDPattern options:0 error:NULL];
  });
  NSRange fullRange = NSMakeRange(0, uploadedID.length);
  NSTextCheckingResult *match = [idRegex firstMatchInString:uploadedID options:0 range:fullRange];
  return match != nil && NSEqualRanges(match.range, fullRange);
}

- (void)showConversationFailure:(NSString *)message {
  self.startConversationButton.enabled = YES;
  self.conversationStatusLabel.textColor = UIColor.systemRedColor;
  self.conversationStatusLabel.text = message;
  self.conversationRetryButton.hidden = NO;
}

/// Loads the provider's ORIGINAL file (not a re-encoded in-memory object --
/// see -downsampledJPEGDataAtURL: for why) and downsamples+re-encodes it to
/// JPEG regardless of source format, PNG included: a 48MP PNG decoded at
/// full resolution is exactly as fatal to the extension's memory limit as a
/// 48MP HEIC. The public.image type identifier here (not a PNG/JPEG-
/// specific one) accepts whatever the provider's native format is.
- (void)loadSessionImageDataFromProvider:(NSItemProvider *)provider
                               completion:(void (^)(NSData *_Nullable data,
                                                     NSString *_Nullable contentType,
                                                     NSString *_Nullable error))completion {
  [provider loadFileRepresentationForTypeIdentifier:kImageType
                                   completionHandler:^(NSURL *url, NSError *error) {
    // url is only valid for the duration of this handler, so the decode +
    // downsample + re-encode has to happen synchronously right here rather
    // than staging the URL away for later -- this handler already runs off
    // the main thread, so doing the work inline doesn't block the UI.
    NSData *jpeg = url ? [self downsampledJPEGDataAtURL:url] : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!jpeg) {
        completion(nil, nil, error.localizedDescription ?: @"could not read/decode image");
        return;
      }
      completion(jpeg, @"image/jpeg", nil);
    });
  }];
}

/// ImageIO thumbnail path: CGImageSourceCreateThumbnailAtIndex decodes
/// directly to the target pixel size without ever materializing the
/// original full-resolution bitmap, unlike +[UIImage imageWithContentsOfURL:]
/// (or -loadObjectOfClass:[UIImage class]) followed by a resize, which
/// decodes full-res first and only THEN throws most of it away -- a 48MP
/// photo is ~190MB as a decoded RGBA bitmap, comfortably past a share
/// extension's ~120MB jetsam ceiling, before a single byte of downsizing
/// has happened. kCGImageSourceThumbnailMaxPixelSize is a cap, not a
/// target, so a smaller source is unaffected; kCGImageSourceCreateThumbnailWithTransform
/// applies the image's EXIF orientation so a downsized photo isn't rotated.
- (nullable NSData *)downsampledJPEGDataAtURL:(NSURL *)url {
  NSDictionary *sourceOptions = @{(id)kCGImageSourceShouldCache : @NO};
  CGImageSourceRef source =
      CGImageSourceCreateWithURL((__bridge CFURLRef)url, (__bridge CFDictionaryRef)sourceOptions);
  if (!source) return nil;

  NSDictionary *thumbnailOptions = @{
    (id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
    (id)kCGImageSourceThumbnailMaxPixelSize : @(kAttachmentMaxPixelSize),
    (id)kCGImageSourceCreateThumbnailWithTransform : @YES,
  };
  CGImageRef thumbnail =
      CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)thumbnailOptions);
  CFRelease(source);
  if (!thumbnail) return nil;

  UIImage *image = [UIImage imageWithCGImage:thumbnail];
  CGImageRelease(thumbnail);
  return UIImageJPEGRepresentation(image, kAttachmentJPEGQuality);
}

/// POSTs to /sessions/upload directly (not through GLDropUploader, whose
/// upload paths are built for /drop's empty-body-on-success contract): this
/// endpoint returns `{"id": "<uuid>.<ext>"}` on 200, and the id is the whole
/// point of the call.
- (void)uploadSessionImageData:(NSData *)data
                    contentType:(NSString *)contentType
                     completion:(void (^)(NSString *_Nullable uploadedID,
                                           NSString *_Nullable error))completion {
  NSString *endpoint = [NSString stringWithFormat:@"http://%@:8302/sessions/upload", GLDropHost];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
  request.HTTPMethod = @"POST";
  request.timeoutInterval = 60;
  [request setValue:[NSString stringWithFormat:@"Bearer %@", GLDropToken]
      forHTTPHeaderField:@"Authorization"];
  [request setValue:contentType forHTTPHeaderField:@"Content-Type"];
  request.HTTPBody = data;

  NSURLSessionDataTask *task = [[NSURLSession sharedSession]
      dataTaskWithRequest:request
        completionHandler:^(NSData *body, NSURLResponse *response, NSError *error) {
    if (error) {
      completion(nil, error.localizedDescription);
      return;
    }
    NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
    if (status < 200 || status > 299) {
      completion(nil, [NSString stringWithFormat:@"HTTP %ld", (long)status]);
      return;
    }
    NSDictionary *json = body ? [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL] : nil;
    NSString *uploadedID = [json isKindOfClass:[NSDictionary class]] ? json[@"id"] : nil;
    if (![uploadedID isKindOfClass:[NSString class]] || uploadedID.length == 0) {
      completion(nil, @"malformed server response");
      return;
    }
    completion(uploadedID, nil);
  }];
  [task resume];
}

#pragma mark - Opening the containing app

- (void)openSessionWithAttachmentIDs:(NSArray<NSString *> *)ids {
  NSString *joined = [ids componentsJoinedByString:@","];
  NSCharacterSet *allowed = NSCharacterSet.URLQueryAllowedCharacterSet;
  NSString *encoded = [joined stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: joined;
  NSString *urlString =
      [NSString stringWithFormat:@"overland://session/text?attach=%@", encoded];
  NSURL *url = [NSURL URLWithString:urlString];

  __weak __typeof(self) weakSelf = self;
  [self openContainingAppURL:url
                   completion:^(BOOL success) {
    __typeof(self) strongSelf = weakSelf;
    if (!strongSelf) return;
    if (!success) {
      strongSelf.conversationInFlight = NO;
      [strongSelf showConversationFailure:@"Couldn't open the app — tap Retry."];
      return;
    }
    if (!strongSelf.dropUploadAttemptFinished) {
      // The /drop auto-upload is still running on the same NSURLSession
      // sharedSession as this extension process -- completing the request
      // now tears the process down and kills that task mid-flight. Wait for
      // -markDropAttemptFinished (called from /drop's dispatch_group_notify,
      // success or failure) to actually end the extension.
      strongSelf.conversationStatusLabel.text = @"Finishing desktop upload…";
      strongSelf.completePendingDropFinish = YES;
      return;
    }
    [strongSelf.extensionContext completeRequestReturningItems:@[] completionHandler:nil];
  }];
}

/// Share extensions run in their own process with no `UIApplication` of
/// their own (`+[UIApplication sharedApplication]` is NS_EXTENSION_UNAVAILABLE
/// and returns nil even if called), so there is no public, compile-time-legal
/// way to ask the containing app to open a URL from here. The long-standing
/// workaround (used by Action/Share extensions for years, predating
/// `NSExtensionContext -openURL:completionHandler:`'s more restricted
/// chooser-style behavior for custom schemes) is to walk the responder chain
/// to the live `UIApplication` instance and call
/// `-openURL:options:completionHandler:` on it. `-openURL:options:completionHandler:`
/// takes three arguments (url, options dict, completion block), which is
/// beyond what `-performSelector:withObject:withObject:` can pass (it caps
/// at two), so this goes through `NSInvocation` instead; the single-argument
/// `-openURL:` some older references use is also known to return NO on
/// iOS 18+ for this cross-process case.
///
/// The completion handler passed down to the responder chain is a private
/// framework contract, not a documented guarantee -- some iOS versions/host
/// contexts are known to just never call it. Without a fallback, a user
/// hitting that case sees "Opening…" forever with no way out except
/// force-quitting the share sheet. `completion` is guarded so ONLY the
/// first of {the real callback, the ~4s timeout} actually fires.
- (void)openContainingAppURL:(NSURL *)url completion:(void (^)(BOOL success))completion {
  __block BOOL didComplete = NO;
  void (^completeOnce)(BOOL) = ^(BOOL success) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (didComplete) return;
      didComplete = YES;
      completion(success);
    });
  };

  // Only UIApplication will do. UIWindowScene sits earlier in the chain and
  // ALSO responds to openURL:options:completionHandler: (with a
  // UISceneOpenExternalURLOptions, not a dictionary), but the extension's
  // hosted scene can't open another app -- stopping at the first responder
  // that matches the selector hit the scene and the app never opened.
  // UIApplication's class is usable from an extension; only
  // +sharedApplication is extension-unavailable.
  Class applicationClass = NSClassFromString(@"UIApplication");
  SEL openSelector = NSSelectorFromString(@"openURL:options:completionHandler:");
  NSMutableArray<NSString *> *chain = [NSMutableArray array];
  UIResponder *responder = self;
  while ((responder = responder.nextResponder) != nil) {
    [chain addObject:NSStringFromClass([responder class])];
    if (![responder isKindOfClass:applicationClass] ||
        ![responder respondsToSelector:openSelector]) {
      continue;
    }
    GLShareDebugLog([NSString stringWithFormat:@"share-open invoking on %@ chain=%@",
                     NSStringFromClass([responder class]),
                     [chain componentsJoinedByString:@">"]]);

    NSMethodSignature *signature = [responder methodSignatureForSelector:openSelector];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.selector = openSelector;
    invocation.target = responder;
    // The invocation object itself goes out of scope the instant -invoke
    // returns, well before openURL:options:completionHandler:'s async work
    // (and its retained completion block) actually runs -- without this,
    // ARC has no reason to keep url/options/completionBlock alive that long.
    [invocation retainArguments];

    NSDictionary *options = @{};
    void (^completionBlock)(BOOL) = ^(BOOL success) {
      GLShareDebugLog([NSString stringWithFormat:@"share-open completion success=%d", success]);
      completeOnce(success);
    };
    [invocation setArgument:&url atIndex:2];
    [invocation setArgument:&options atIndex:3];
    [invocation setArgument:&completionBlock atIndex:4];
    [invocation invoke];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      if (!didComplete) GLShareDebugLog(@"share-open timed out after 4s");
      completeOnce(NO);
    });
    return;
  }
  GLShareDebugLog([NSString stringWithFormat:@"share-open no UIApplication in chain=%@",
                   [chain componentsJoinedByString:@">"]]);
  completeOnce(NO);
}

@end
