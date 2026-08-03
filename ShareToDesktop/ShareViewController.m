#import "ShareViewController.h"
#import "ShareConfig.h"
#import "../Shared/GLDropUploader.h"

// Share-sheet extension: takes the images handed to it and POSTs the raw bytes
// to the Linux box's location server (/drop). No compose field — the upload
// starts as soon as the sheet appears and the sheet dismisses itself when every
// item has landed.
//
// Everything runs on a plain NSURLSession with completion handlers, and
// -completeRequestReturningItems: is called only after ALL uploads have
// finished; an extension that completes early is killed mid-flight and the
// upload silently disappears.

static NSString *const kImageType = @"public.image";
static NSString *const kMovieType = @"public.movie";
static const NSUInteger kMaxItems = 10;

@interface ShareViewController ()
@property(nonatomic, strong) NSArray<NSItemProvider *> *providers;
@property(nonatomic, strong) NSMutableArray<UILabel *> *rowLabels;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIButton *retryButton;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic, assign) BOOL started;
@end

@implementation ShareViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  self.providers = [self collectProviders];
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

  UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
  [cancel setTitle:@"Cancel" forState:UIControlStateNormal];
  [cancel addTarget:self
                action:@selector(cancelTapped)
      forControlEvents:UIControlEventTouchUpInside];

  UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[ cancel, self.retryButton ]];
  buttons.axis = UILayoutConstraintAxisHorizontal;
  buttons.spacing = 24;
  buttons.distribution = UIStackViewDistributionFillEqually;

  UIStackView *stack = [[UIStackView alloc]
      initWithArrangedSubviews:@[ title, self.spinner, self.statusLabel, rows, buttons ]];
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

- (void)cancelTapped {
  [self.extensionContext cancelRequestWithError:[NSError errorWithDomain:@"ShareToDesktop"
                                                                    code:1
                                                                userInfo:nil]];
}

#pragma mark - Upload

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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     [self.extensionContext completeRequestReturningItems:@[] completionHandler:nil];
                   });
  });
}

@end
