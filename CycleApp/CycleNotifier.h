#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

extern NSString *const CycleNotifierErrorDomain;
/// userInfo key carrying the route the page asked for; read back when the notification is tapped.
extern NSString *const CycleNotificationRouteKey;
/// userInfo keys of an upset check-in: the upset id, and the `next` payload (title, body, rest, delayMs or morning) the page prepared
/// so the shell can schedule the following ask itself when "Still feeling it" is tapped with the page not running.
extern NSString *const CycleNotificationUpsetIDKey;
extern NSString *const CycleNotificationNextKey;
/// Category and action identifiers of the "Still feeling this?" check-in.
extern NSString *const CycleNotificationCategoryUpsetCheck;
extern NSString *const CycleUpsetActionStill;
extern NSString *const CycleUpsetActionPassed;
/// Store key prefix of a button answer awaiting the page: `upsetAnswers:<id>:<at>` -> {id, ans, at}. One key per answer, so
/// two answers never read-modify-write the same value; the page drains and deletes them.
extern NSString *const CycleUpsetAnswerKeyPrefix;

/// The slice of UNUserNotificationCenter the notifier uses, so tests can substitute a fake.
NS_ASSUME_NONNULL_BEGIN
@protocol CycleNotificationCenter <NSObject>
- (void)addNotificationRequest:(UNNotificationRequest *)request withCompletionHandler:(void (^__nullable)(NSError *__nullable error))completionHandler;
- (void)removePendingNotificationRequestsWithIdentifiers:(NSArray<NSString *> *)identifiers;
- (void)removeDeliveredNotificationsWithIdentifiers:(NSArray<NSString *> *)identifiers;
- (void)getNotificationSettingsWithCompletionHandler:(void (^)(UNNotificationSettings *))completionHandler;
/// Authorization state alone (the real centre derives it from its settings); tests answer it directly.
- (void)getAuthorizationStatusWithCompletionHandler:(void (^)(UNAuthorizationStatus status))completionHandler;
- (void)requestAuthorizationWithOptions:(UNAuthorizationOptions)options completionHandler:(void (^)(BOOL granted, NSError *__nullable error))completionHandler;
@end
NS_ASSUME_NONNULL_END

@interface UNUserNotificationCenter (CycleNotificationCenter) <CycleNotificationCenter>
@end

/// Local notifications for the bridge's notify.* commands. The notification identifier is the id
/// the page gives, so scheduling an id that is already pending replaces the earlier one.
@interface CycleNotifier : NSObject

- (instancetype)initWithCenter:(id<CycleNotificationCenter>)center;

/// Builds the request for notify.schedule args {id, at (epoch ms), title, body, route} plus optional category (a category
/// identifier), upsetId and next (kept in userInfo for the action handler).
/// nil + *error when an arg is missing/mistyped or `at` is not after `now`.
+ (NSString *)statusStringForAuthorization:(UNAuthorizationStatus)status;
+ (UNNotificationRequest *)requestForArgs:(NSDictionary *)args now:(NSDate *)now error:(NSError **)error;

/// Granted state; prompts on the first call (authorization not yet determined).
- (void)permissionWithCompletion:(void (^)(BOOL granted))completion;
/// 'granted' | 'denied' | 'notDetermined'; never prompts.
- (void)statusWithCompletion:(void (^)(NSString *status))completion;
/// completion(error) runs on an arbitrary queue; nil error = scheduled.
- (void)scheduleArgs:(NSDictionary *)args now:(NSDate *)now completion:(void (^)(NSError *error))completion;
/// Removes the pending request and any already-delivered one with this id.
- (void)cancelID:(NSString *)identifier;

@end

/// Upset check-in buttons. Neither action has the foreground option, so tapping one does not open the app.
@interface CycleNotifier (UpsetCheck)
/// The categories to register with the notification centre.
+ (NSSet<UNNotificationCategory *> *)categories;
/// The answer {id, ans ('still'|'passed'), at (ISO-8601 UTC)} for a tapped action; nil when the action is not an upset button or the
/// notification carries no upset id.
+ (NSDictionary *)upsetAnswerForAction:(NSString *)action userInfo:(NSDictionary *)userInfo now:(NSDate *)now;
/// notify.schedule args for the ask that follows a "still" answered at `now`: `next.delayMs` after now, or the next 9:00 local (in
/// `calendar`) at least an hour away for `next.morning`. nil when the notification carried no `next`.
+ (NSDictionary *)nextCheckArgsForUserInfo:(NSDictionary *)userInfo now:(NSDate *)now calendar:(NSCalendar *)calendar;
@end
