#import <UIKit/UIKit.h>

/// Import tab: a paste box, a "Parse" step that shows a preview table
/// (QuotesImportParser does the actual parsing), and "Save N Quotes" which
/// dedupes against the store and appends. See QuotesImportParser.h for the
/// recognized formats.
@interface QuotesImportViewController : UIViewController

/// Fired after a successful save. QuotesViewController doesn't strictly
/// need this today (it re-reads the store on every appearance/segment
/// switch anyway) but it's the natural extension point for anything that
/// should react to an import completing.
@property(nonatomic, copy, nullable) void (^onQuotesImported)(void);

@end
