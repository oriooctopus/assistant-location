#import "ShareViewController.h"
#import "ShareConfig.h"
#import "../Shared/GLDropUploader.h"

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
static NSString *const kMovieType = @"public.movie";
static NSString *const kPNGType = @"public.png";
static NSString *const kJPEGType = @"public.jpeg";
static const NSUInteger kMaxItems = 10;
static const NSUInteger kMaxConversationItems = 5;

@interface ShareViewController ()
@property(nonatomic, strong) NSArray<NSItemProvider *> *providers;
@property(nonatomic, strong) NSArray<NSItemProvider *> *imageProviders;
@property(nonatomic, strong) NSMutableArray<UILabel *> *rowLabels;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIButton *retryButton;
@property(nonatomic, strong) UIButton *doneButton;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic, assign) BOOL started;
@property(nonatomic, assign) BOOL dropUploadsDone;

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
/// attachments; flatten them and keep the images and videos, capped at
/// kMaxItems.
- (NSArray<NSItemProvider *> *)collectProviders {
  NSMutableArray<NSItemProvider *> *out = [NSMutableArray array];
  for (NSExtensionItem *item in self.extensionContext.inputItems) {
    for (NSItemProvider *provider in item.attachments) {
      BOOL usable = [provider hasItemConformingToTypeIdentifier:kImageType] ||
                    [provider hasItemConformingToTypeIdentifier:kMovieType];
      if (usable && out.count < kMaxItems) {
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
  [self startUploads];
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
    [self showFailure:@"Nothing to upload — no images or videos were shared."];
    return;
  }
  if ([GLDropToken isEqualToString:@"NO_TOKEN_BAKED_IN"]) {
    [self showFailure:@"No token baked in — this build cannot upload."];
    return;
  }
  if ([GLDropHost isEqualToString:@"NO_HOST_BAKED_IN"]) {
    [self showFailure:@"No host baked in — this build cannot upload."];
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
  self.conversationStatusLabel.text =
      [NSString stringWithFormat:@"Uploading 0/%lu…", (unsigned long)self.imageProviders.count];

  NSUInteger count = self.imageProviders.count;
  // Ordered results array -- filled in by index so the final id list matches
  // provider (and therefore visual attachment) order regardless of which
  // upload finishes first.
  NSMutableArray<NSString *> *uploadedIDs = [NSMutableArray arrayWithCapacity:count];
  for (NSUInteger i = 0; i < count; i++) {
    [uploadedIDs addObject:[NSNull null]];
  }
  __block NSUInteger completedCount = 0;
  __block NSString *firstError = nil;
  dispatch_group_t group = dispatch_group_create();

  [self.imageProviders enumerateObjectsUsingBlock:^(NSItemProvider *provider, NSUInteger idx, BOOL *stop) {
    dispatch_group_enter(group);
    [self loadSessionImageDataFromProvider:provider
                                 completion:^(NSData *data, NSString *contentType, NSString *loadError) {
      if (!data) {
        if (!firstError) firstError = loadError ?: @"could not read image";
        dispatch_group_leave(group);
        return;
      }
      [self uploadSessionImageData:data
                        contentType:contentType
                         completion:^(NSString *uploadedID, NSString *uploadError) {
        dispatch_async(dispatch_get_main_queue(), ^{
          if (uploadedID) {
            uploadedIDs[idx] = uploadedID;
            completedCount++;
            self.conversationStatusLabel.text =
                [NSString stringWithFormat:@"Uploading %lu/%lu…",
                                            (unsigned long)completedCount, (unsigned long)count];
          } else if (!firstError) {
            firstError = uploadError ?: @"upload failed";
          }
        });
        dispatch_group_leave(group);
      }];
    }];
  }];

  dispatch_group_notify(group, dispatch_get_main_queue(), ^{
    self.conversationInFlight = NO;
    // Never proceed with a missing id: a partial attach list would silently
    // drop an image the user picked, with no way for them to notice.
    if (firstError || [uploadedIDs containsObject:[NSNull null]]) {
      [self showConversationFailure:firstError ?: @"one or more uploads failed"];
      return;
    }
    self.conversationStatusLabel.textColor = UIColor.secondaryLabelColor;
    self.conversationStatusLabel.text = @"Opening…";
    [self openSessionWithAttachmentIDs:uploadedIDs];
  });
}

- (void)showConversationFailure:(NSString *)message {
  self.startConversationButton.enabled = YES;
  self.conversationStatusLabel.textColor = UIColor.systemRedColor;
  self.conversationStatusLabel.text = message;
  self.conversationRetryButton.hidden = NO;
}

/// The server only accepts png/jpeg/gif/webp (magic-byte sniff, 415
/// otherwise) — a PNG or JPEG provider is uploaded as-is (its original bytes,
/// not a re-encode), everything else (HEIC is the common case: that's what
/// the Photos picker vends by default) is loaded as a UIImage and re-encoded
/// to JPEG. No file-staging here (unlike GLDropUploader's /drop path): these
/// are camera/screenshot-sized stills, not video, so holding one in memory
/// is fine, and /sessions/upload's response body (the {id}) has to come back
/// through the same in-memory round trip anyway.
- (void)loadSessionImageDataFromProvider:(NSItemProvider *)provider
                               completion:(void (^)(NSData *_Nullable data,
                                                     NSString *_Nullable contentType,
                                                     NSString *_Nullable error))completion {
  BOOL isPNG = [provider hasItemConformingToTypeIdentifier:kPNGType];
  BOOL isJPEG = !isPNG && [provider hasItemConformingToTypeIdentifier:kJPEGType];
  if (!isPNG && !isJPEG) {
    [self loadSessionImageAsJPEGFromProvider:provider completion:completion];
    return;
  }

  NSString *type = isPNG ? kPNGType : kJPEGType;
  NSString *contentType = isPNG ? @"image/png" : @"image/jpeg";
  [provider loadDataRepresentationForTypeIdentifier:type
                                   completionHandler:^(NSData *data, NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (data.length > 0) {
        completion(data, contentType, nil);
        return;
      }
      // The provider claimed the type but couldn't actually vend it --
      // salvage via the same re-encode path used for HEIC etc.
      [self loadSessionImageAsJPEGFromProvider:provider completion:completion];
    });
  }];
}

- (void)loadSessionImageAsJPEGFromProvider:(NSItemProvider *)provider
                                 completion:(void (^)(NSData *_Nullable data,
                                                       NSString *_Nullable contentType,
                                                       NSString *_Nullable error))completion {
  [provider loadObjectOfClass:[UIImage class]
             completionHandler:^(UIImage *image, NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (![image isKindOfClass:[UIImage class]]) {
        completion(nil, nil, error.localizedDescription ?: @"could not read image");
        return;
      }
      NSData *jpeg = UIImageJPEGRepresentation(image, 0.9);
      if (!jpeg) {
        completion(nil, nil, @"could not encode image");
        return;
      }
      completion(jpeg, @"image/jpeg", nil);
    });
  }];
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
    if (success) {
      [strongSelf.extensionContext completeRequestReturningItems:@[] completionHandler:nil];
      return;
    }
    [strongSelf showConversationFailure:@"Couldn't open the app — try again."];
  }];
}

/// Share extensions run in their own process with no `UIApplication` of
/// their own (`+[UIApplication sharedApplication]` is NS_EXTENSION_UNAVAILABLE
/// and returns nil even if called), so there is no public, compile-time-legal
/// way to ask the containing app to open a URL from here. The long-standing
/// workaround (used by Action/Share extensions for years, predating
/// `NSExtensionContext -openURL:completionHandler:`'s more restricted
/// chooser-style behavior for custom schemes) is to walk the responder chain
/// looking for the first object that responds to
/// `-openURL:options:completionHandler:` -- in practice this resolves to the
/// live `UIApplication` instance one hop up. `-openURL:options:completionHandler:`
/// takes three arguments (url, options dict, completion block), which is
/// beyond what `-performSelector:withObject:withObject:` can pass (it caps
/// at two), so this goes through `NSInvocation` instead; the single-argument
/// `-openURL:` some older references use is also known to return NO on
/// iOS 18+ for this cross-process case.
- (void)openContainingAppURL:(NSURL *)url completion:(void (^)(BOOL success))completion {
  SEL openSelector = NSSelectorFromString(@"openURL:options:completionHandler:");
  UIResponder *responder = self;
  while ((responder = responder.nextResponder) != nil) {
    if (![responder respondsToSelector:openSelector]) continue;

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
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(success);
      });
    };
    [invocation setArgument:&url atIndex:2];
    [invocation setArgument:&options atIndex:3];
    [invocation setArgument:&completionBlock atIndex:4];
    [invocation invoke];
    return;
  }
  completion(NO);
}

@end
