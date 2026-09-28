// GLWebModuleViewController for questions.html. Adds one thing: a Marketplace
// push tap (EsmeNotificationDelegate posts kQuestionsOpenNotification with
// {listing, buyer}) opens this screen and calls window.openQuestion(ref) in
// the page, which shows that question's answer view.

#import "GLWebModuleViewController.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString *const kQuestionsOpenNotification;

@interface QuestionsViewController : GLWebModuleViewController
/// Opens the Questions screen and delivers `ref` ({listing, buyer}) to the page.
+ (void)handleOpenRequest:(NSDictionary *)ref;
@end

NS_ASSUME_NONNULL_END
