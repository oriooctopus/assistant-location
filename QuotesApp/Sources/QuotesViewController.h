#import <UIKit/UIKit.h>

/// Today screen of the standalone Quotes app (Swiss grid): the quote the rules
/// pick right now, the day number, a Save control, and text links that push
/// Index (Browse), Add (Import) and Rules (Schedule). Hosted in a
/// UINavigationController with the bar hidden (QuotesAppDelegate).
@interface QuotesViewController : UIViewController
/// Shows the quote with `quoteId` (a tapped daily notification) instead of the
/// rules' current pick, popping any pushed screen. The Today link returns to
/// the current pick.
- (void)openQuoteWithId:(NSString *)quoteId;
@end
