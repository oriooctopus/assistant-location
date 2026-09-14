#import <UIKit/UIKit.h>

/// Root of the Quotes tab: a "Preview now" row (which quote the widget
/// would show right now, per the current rules) above a segmented Browse /
/// Import / Schedule switcher. Wrapped in a UINavigationController by
/// QuotesModule so Schedule can push a rule-edit screen.
@interface QuotesViewController : UIViewController
@end
