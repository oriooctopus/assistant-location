#import <UIKit/UIKit.h>

/// Full-screen WKWebView hosting the bundled questions.html (Questions / Reply / Sold).
@interface MarketplaceViewController : UIViewController

/// Opens the answer view for a question; waits for the page if it has not loaded yet (cold launch).
- (void)openQuestionWithListing:(NSString *)listing buyer:(NSString *)buyer;
/// Hands the page a /questions payload (window.applyQuestions) so a tapped notification's thread is already there.
- (void)applyPrefetchedQuestions:(NSDictionary *)payload;
/// Re-fetches the list (a push may have arrived while backgrounded).
- (void)refresh;

@end
