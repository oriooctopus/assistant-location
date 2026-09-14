#import <UIKit/UIKit.h>

#import "QuotesModels.h"

/// Add/edit screen for one GLQuoteRule, pushed from QuotesScheduleViewController.
/// Filter-kind rules pick authors/genres from what's currently in the store;
/// AI-kind rules get a prompt field plus a resolve step against
/// /quotes/ai-filter (auto-run on Save when the prompt is new/changed, and
/// from a manual "Re-run" button) -- see QuotesAIFilterClient.
@interface QuotesRuleEditViewController : UIViewController

- (instancetype)initWithRule:(GLQuoteRule *)rule isNew:(BOOL)isNew NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end
