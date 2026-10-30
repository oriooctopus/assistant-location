#import "ClipScoreViewController.h"

#import <PDFKit/PDFKit.h>

#import "GLLog.h"
#import "GLTheme.h"

@interface ClipScoreViewController ()
@property (nonatomic, strong) NSURL *fileURL;
@property (nonatomic, strong) PDFView *pdfView;
@end

@implementation ClipScoreViewController

- (instancetype)initWithFileURL:(NSURL *)fileURL {
    self = [super initWithNibName:nil bundle:nil];
    if (self) _fileURL = fileURL;
    return self;
}

- (NSInteger)pageCount { return self.pdfView.document.pageCount; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [GLTheme backgroundColor];

    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    [done setTitle:@"Done" forState:UIControlStateNormal];
    done.titleLabel.font = [GLTheme buttonFont];
    done.tintColor = [GLTheme accentColor];
    done.translatesAutoresizingMaskIntoConstraints = NO;
    [done addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:done];

    self.pdfView = [[PDFView alloc] init];
    self.pdfView.translatesAutoresizingMaskIntoConstraints = NO;
    self.pdfView.displayMode = kPDFDisplaySinglePageContinuous;
    self.pdfView.displayDirection = kPDFDisplayDirectionVertical;
    self.pdfView.autoScales = YES;
    self.pdfView.backgroundColor = [GLTheme backgroundColor];
    self.pdfView.document = [[PDFDocument alloc] initWithURL:self.fileURL];
    if (!self.pdfView.document) GLLog(@"clips score: cannot read %@", self.fileURL);
    [self.view addSubview:self.pdfView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [done.topAnchor constraintEqualToAnchor:safe.topAnchor constant:[GLTheme spacingS]],
        [done.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:[GLTheme spacingM]],
        [self.pdfView.topAnchor constraintEqualToAnchor:done.bottomAnchor constant:[GLTheme spacingS]],
        [self.pdfView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.pdfView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.pdfView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

@end
