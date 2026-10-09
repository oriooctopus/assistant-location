// "Swiss grid" look for the standalone Quotes app. Quotes-local on purpose:
// GLTheme/GLComponents are shared with every Overland module, so none of this
// touches them. One face (Helvetica Neue Regular), one accent (red), paper and
// ink colours that flip for dark mode, 0.5pt hairlines, no corner radius.
//
// The method names mirror the GLTheme/GLComponents ones the Quotes screens
// used, so a screen restyles by swapping the class name.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Grid cells (pure, unit-tested)

/// A cell on the Today screen's grid, 1-based: col 1...6, row 1...8.
typedef struct {
    NSInteger col;
    NSInteger row;
} QuotesGridCell;

extern const NSInteger QuotesGridColumns; // 6
extern const NSInteger QuotesGridRows;    // 8

/// YES for cells the decorative circle must never occupy on Today: the whole
/// top row (day number, nav links), the date line under the number, and
/// everything from row 4 down (quote block, author, footer).
BOOL QuotesTodayCellIsReserved(QuotesGridCell cell);

/// Where the decorative red circle sits on `date`: a pure function of the
/// calendar day, walking a fixed closed loop one cell per day through cells
/// that are never reserved.
QuotesGridCell QuotesDecorativeCircleCell(NSDate *date, NSCalendar *calendar);

#pragma mark - Paging (pure, unit-tested)

/// YES when the quote list can move `delta` places from `index` without leaving 0...count-1.
BOOL QuotesPageCanMove(NSInteger index, NSInteger delta, NSInteger count);

/// `index` moved by `delta`, clamped to 0...count-1 (the Today pager does not wrap).
NSInteger QuotesPageIndexAfter(NSInteger index, NSInteger delta, NSInteger count);

/// The "Today" link shows only while the viewed quote is not today's.
BOOL QuotesPageShowsTodayLink(NSInteger viewing, NSInteger today);

/// Where the "Today" link takes you.
NSInteger QuotesPageIndexForTodayTap(NSInteger viewing, NSInteger today);

/// The small grey meta line under the author: "0034 / 101" (index is 0-based).
NSString *QuotesPageMetaText(NSInteger index, NSInteger count);

#pragma mark - Theme

@interface QuotesTheme : NSObject

+ (UIColor *)paper;
+ (UIColor *)ink;
+ (UIColor *)red;
+ (UIColor *)hairline;
+ (UIColor *)grey;     // secondary text
+ (UIColor *)dayGrey;  // the big day number

// GLTheme-shaped aliases.
+ (UIColor *)backgroundColor;
+ (UIColor *)surfaceColor;
+ (UIColor *)accentColor;
+ (UIColor *)destructiveColor;
+ (UIColor *)textPrimaryColor;
+ (UIColor *)textSecondaryColor;

+ (UIFont *)fontOfSize:(CGFloat)size;
+ (UIFont *)titleFont;   // 18
+ (UIFont *)bodyFont;    // 16
+ (UIFont *)buttonFont;  // 13
+ (UIFont *)captionFont; // 11

+ (CGFloat)spacingXXS;
+ (CGFloat)spacingXS;
+ (CGFloat)spacingS;
+ (CGFloat)spacingM;
+ (CGFloat)spacingL;
+ (CGFloat)cornerRadius; // 0
+ (CGFloat)controlHeight;

/// Applies paper background + ink tint to a screen's root view.
+ (void)styleScreenView:(UIView *)view;
/// Hairline border, flat paper fill, for text fields and text views.
+ (void)styleField:(UIView *)field;
/// Plain text link, tappable area at least 44pt tall.
+ (UIButton *)textLinkWithTitle:(NSString *)title;

+ (UIButton *)primaryButtonWithTitle:(NSString *)title;
+ (UILabel *)statusLabel;
+ (UIView *)emptyStateViewWithMessage:(NSString *)message;
+ (void)showToastInView:(UIView *)view message:(NSString *)message;

/// Reserves a 44pt strip under the status bar on a pushed screen and puts a
/// "Back" text link plus hairline in it. The nav bar is hidden app-wide.
+ (void)installBackLinkInViewController:(UIViewController *)viewController;

@end

#pragma mark - Views

/// Hairline column/row grid drawn over the whole view.
@interface QuotesGridView : UIView
@property(nonatomic, assign) NSInteger columns;
@property(nonatomic, assign) NSInteger rows;
@end

/// Flat text toggle ("All / Saved"): the selected cell is ink with paper text,
/// the others a hairline box with grey text. Same selectedSegmentIndex /
/// UIControlEventValueChanged contract as UISegmentedControl.
@interface QuotesToggle : UIControl
@property(nonatomic, assign) NSInteger selectedSegmentIndex;
/// 0 = cells share the frame's width equally.
@property(nonatomic, assign) CGFloat cellWidth;
- (instancetype)initWithItems:(NSArray<NSString *> *)items;
@end

/// The Save control: optional word plus a circle, red outline when unsaved and
/// red fill when saved. The whole frame is the tap target.
@interface QuotesSaveControl : UIControl
@property(nonatomic, assign) BOOL saved;
/// YES centres the circle in the frame (Browse rows); NO right-aligns it with
/// the word to its left (Today footer).
@property(nonatomic, assign) BOOL circleCentered;
- (instancetype)initWithDiameter:(CGFloat)diameter showsWord:(BOOL)showsWord;
@end

NS_ASSUME_NONNULL_END
