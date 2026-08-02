#import "GLUploadViewController.h"

#import <PhotosUI/PhotosUI.h>

#import "BakedConfig.h"
#import "GLDropUploader.h"

// Same cap as the share extension, for the same reason: a picker that hands
// back fifty screenshots turns one tap into a very long upload.
static const NSUInteger kMaxItems = 10;

/// One picked image and where its upload has got to. Retry re-runs only the
/// rows that are still unfinished, so a partial failure doesn't re-send the
/// items that already landed.
@interface GLUploadItem : NSObject
@property(nonatomic, strong) NSItemProvider *provider;
@property(nonatomic, strong) NSString *filename;
@property(nonatomic, copy) NSString *state;
@property(nonatomic, assign) BOOL succeeded;
@property(nonatomic, strong) UILabel *label;
@end

@implementation GLUploadItem
@end

@interface GLUploadViewController () <PHPickerViewControllerDelegate>
@property(nonatomic, strong) UIButton *chooseButton;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIStackView *rowsStack;
@property(nonatomic, strong) UIButton *retryButton;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic, strong) NSMutableArray<GLUploadItem *> *items;
@end

@implementation GLUploadViewController

#pragma mark - Lifecycle

- (instancetype)init {
    self = [super init];
    if (self) {
        // Title, icon and restoration identifier are set by GLModuleRegistry
        // from UploadModule — a module never configures its own tab bar item.
        _items = [NSMutableArray array];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    [self buildUI];
}

#pragma mark - UI

- (void)buildUI {
    UILabel *title = [[UILabel alloc] init];
    title.text = @"Upload to desktop";
    title.font = [UIFont boldSystemFontOfSize:18];
    title.textAlignment = NSTextAlignmentCenter;

    self.chooseButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.chooseButton setTitle:@"Choose Photos" forState:UIControlStateNormal];
    self.chooseButton.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    self.chooseButton.backgroundColor = UIColor.systemBlueColor;
    [self.chooseButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.chooseButton.layer.cornerRadius = 10;
    [self.chooseButton.heightAnchor constraintEqualToConstant:48].active = YES;
    [self.chooseButton addTarget:self
                          action:@selector(chooseTapped)
                forControlEvents:UIControlEventTouchUpInside];

    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.font = [UIFont systemFontOfSize:13];
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.text = @"Pick up to 10 images to send to the desktop.";

    self.rowsStack = [[UIStackView alloc] init];
    self.rowsStack.axis = UILayoutConstraintAxisVertical;
    self.rowsStack.spacing = 4;

    self.retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.retryButton setTitle:@"Retry" forState:UIControlStateNormal];
    [self.retryButton addTarget:self
                         action:@selector(retryTapped)
               forControlEvents:UIControlEventTouchUpInside];
    self.retryButton.hidden = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        title, self.chooseButton, self.spinner, self.statusLabel, self.rowsStack, self.retryButton
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:guide.topAnchor constant:24],
        [stack.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-16],
    ]];
}

#pragma mark - Picking

- (void)chooseTapped {
    PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
    config.selectionLimit = kMaxItems;
    config.filter = [PHPickerFilter imagesFilter];
    PHPickerViewController *picker =
        [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker
    didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) {
        return;
    }

    [self.items removeAllObjects];
    for (UIView *row in self.rowsStack.arrangedSubviews) {
        [self.rowsStack removeArrangedSubview:row];
        [row removeFromSuperview];
    }

    NSUInteger index = 0;
    for (PHPickerResult *result in results) {
        GLUploadItem *item = [[GLUploadItem alloc] init];
        item.provider = result.itemProvider;
        item.label = [[UILabel alloc] init];
        item.label.font = [UIFont monospacedDigitSystemFontOfSize:13
                                                           weight:UIFontWeightRegular];
        item.label.lineBreakMode = NSLineBreakByTruncatingMiddle;
        item.label.text = [NSString stringWithFormat:@"%lu. waiting…", (unsigned long)(index + 1)];
        [self.rowsStack addArrangedSubview:item.label];
        [self.items addObject:item];
        index++;
    }

    [self startUploads];
}

#pragma mark - Uploading

- (void)setItem:(GLUploadItem *)item text:(NSString *)text {
    NSUInteger index = [self.items indexOfObject:item];
    dispatch_async(dispatch_get_main_queue(), ^{
        item.state = text;
        item.label.text =
            [NSString stringWithFormat:@"%lu. %@", (unsigned long)(index + 1), text];
    });
}

- (void)startUploads {
    if ([GL_BAKED_TOKEN isEqualToString:@"NO_TOKEN_BAKED_IN"]) {
        [self finishWithMessage:@"No token baked in — this build cannot upload."
                        failed:YES];
        return;
    }
    NSString *endpoint = [GLDropUploader dropEndpointForLocationEndpoint:GL_BAKED_ENDPOINT];

    self.retryButton.hidden = YES;
    self.chooseButton.enabled = NO;
    [self.spinner startAnimating];
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.text = @"Uploading…";

    __block NSString *firstError = nil;
    dispatch_group_t group = dispatch_group_create();

    for (GLUploadItem *item in self.items) {
        if (item.succeeded) {
            continue;
        }
        NSUInteger index = [self.items indexOfObject:item];
        dispatch_group_enter(group);
        [self setItem:item text:@"loading…"];
        [GLDropUploader
            loadImageFromProvider:item.provider
                            index:index
                       completion:^(NSData *data, NSString *filename, NSString *contentType,
                                    NSString *error) {
            if (!data) {
                [self setItem:item text:[NSString stringWithFormat:@"failed — %@", error]];
                if (!firstError) firstError = error;
                dispatch_group_leave(group);
                return;
            }
            item.filename = filename;
            [self setItem:item
                     text:[NSString stringWithFormat:@"%@ — uploading…", filename]];
            [GLDropUploader uploadData:data
                              filename:filename
                           contentType:contentType
                            toEndpoint:endpoint
                                 token:GL_BAKED_TOKEN
                            completion:^(NSString *uploadError) {
                if (uploadError) {
                    [self setItem:item
                             text:[NSString stringWithFormat:@"%@ — failed: %@", filename,
                                                             uploadError]];
                    if (!firstError) firstError = uploadError;
                } else {
                    item.succeeded = YES;
                    [self setItem:item
                             text:[NSString stringWithFormat:@"%@ — Uploaded ✓", filename]];
                }
                dispatch_group_leave(group);
            }];
        }];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        if (firstError) {
            [self finishWithMessage:firstError failed:YES];
        } else {
            [self finishWithMessage:@"Uploaded ✓" failed:NO];
        }
    });
}

- (void)finishWithMessage:(NSString *)message failed:(BOOL)failed {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.spinner stopAnimating];
        self.chooseButton.enabled = YES;
        self.statusLabel.textColor = failed ? UIColor.systemRedColor : UIColor.secondaryLabelColor;
        self.statusLabel.text = message;
        self.retryButton.hidden = !failed;
    });
}

- (void)retryTapped {
    [self startUploads];
}

@end
