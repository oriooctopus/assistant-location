#import <UIKit/UIKit.h>

/// Browse tab: every quote (stock + imported), filterable by author/genre,
/// with swipe-to-delete on imported quotes only. Reloads from QuotesStore
/// whenever -reload is called (QuotesViewController calls it on every
/// segment switch, since Import/Schedule can both change what's here).
@interface QuotesBrowseViewController : UIViewController
- (void)reload;
@end
