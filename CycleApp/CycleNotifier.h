#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

extern NSString *const CycleNotifierErrorDomain;
/// userInfo key carrying the route the page asked for; read back when the notification is tapped.
extern NSString *const CycleNotificationRouteKey;

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

/// Builds the request for notify.schedule args {id, at (epoch ms), title, body, route}.
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
