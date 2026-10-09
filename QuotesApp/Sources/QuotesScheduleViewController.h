#import <UIKit/UIKit.h>

/// Schedule tab: the default rotation interval, plus the ordered list of
/// rules (add/edit/reorder/delete). Rule order IS priority -- the first
/// whose day/time window contains "now" wins, see QuotesRuleEngine. Reloads
/// from QuotesStore whenever -reload is called.
@interface QuotesScheduleViewController : UIViewController
- (void)reload;
@end
