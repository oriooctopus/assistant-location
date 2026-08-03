//
//  GLManager.h
//  App
//
//  Created by Aaron Parecki on 9/17/15.
//  Copyright © 2015 Esri. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <CoreMotion/CoreMotion.h>
@import UserNotifications;

static NSString *const GLNewDataNotification = @"GLNewDataNotification";
static NSString *const GLNewActivityNotification = @"GLNewActivityNotification";
static NSString *const GLAuthorizationStatusChangedNotification = @"GLAuthorizationStatusChangedNotification";
static NSString *const GLSendingStartedNotification = @"GLSendingStartedNotification";
static NSString *const GLSendingFinishedNotification = @"GLSendingFinishedNotification";
static NSString *const GLSettingsChangedNotification = @"GLSettingsChangedNotification";

static NSString *const GLAPIEndpointDefaultsName = @"GLAPIEndpointDefaults";
static NSString *const GLAPIAccessTokenDefaultsName = @"GLAPIAccessTokenDefaults";
static NSString *const GLDeviceIdDefaultsName = @"GLDeviceIdDefaults";
static NSString *const GLLastSentDateDefaultsName = @"GLLastSentDateDefaults";
static NSString *const GLLastSendAttemptDateDefaultsName = @"GLLastSendAttemptDateDefaults";
static NSString *const GLLastSendStatusDefaultsName = @"GLLastSendStatusDefaults";
static NSString *const GLTrackingStateDefaultsName = @"GLTrackingStateDefaults";
static NSString *const GLSendIntervalDefaultsName = @"GLSendIntervalDefaults";
static NSString *const GLPausesAutomaticallyDefaultsName = @"GLPausesAutomaticallyDefaults";
static NSString *const GLResumesAutomaticallyDefaultsName = @"GLResumesAutomaticallyDefaults";
static NSString *const GLDiscardPointsWithinDistanceDefaultsName = @"GLDiscardPointsWithinDistanceDefaults";
static NSString *const GLDiscardPointsWithinSecondsDefaultsName = @"GLDiscardPointsWithinSecondsDefaults";
static NSString *const GLIncludeTrackingStatsDefaultsName = @"GLIncludeTrackingStatsDefaultsName";
static NSString *const GLActivityTypeDefaultsName = @"GLActivityTypeDefaults";
static NSString *const GLDesiredAccuracyDefaultsName = @"GLDesiredAccuracyDefaults";
static NSString *const GLSignificantLocationModeDefaultsName = @"GLSignificantLocationModeDefaults";
static NSString *const GLPointsPerBatchDefaultsName = @"GLPointsPerBatchDefaults";
static NSString *const GLNotificationPermissionRequestedDefaultsName = @"GLNotificationPermissionRequestedDefaults";
static NSString *const GLNotificationsEnabledDefaultsName = @"GLNotificationsEnabledDefaults";
static NSString *const GLIncludeUniqueIdDefaultsName = @"GLIncludeUniqueIdDefaults";
static NSString *const GLConsiderHTTP200SuccessDefaultsName = @"GLConsiderHTTP200SuccessDefaults";
static NSString *const GLBackgroundIndicatorDefaultsName = @"GLBackgroundIndicatorDefaults";
static NSString *const GLLoggingModeDefaultsName = @"GLLoggingModeDefaults";
static NSString *const GLVisitTrackingEnabledDefaultsName = @"GLVisitTrackingEnabledDefaults";
/* Set once the one-time migration onto significant-change tracking has run.
   Its absence, not the tracking mode itself, is what triggers the migration —
   so a mode chosen manually afterwards is never overwritten. */
static NSString *const GLMigratedToSignificantV1DefaultsName = @"GLMigratedToSignificantV1";

static NSString *const GLPurgeQueueOnNextLaunchDefaultsName = @"GLPurgeQueueOnNextLaunch";
static NSString *const GLLastScheduledNotificationDateDefaultsName = @"GLLastScheduledNotificationDateDefaults";

typedef enum {
    kGLTrackingModeOff,
    kGLTrackingModeStandard,
    kGLTrackingModeSignificant,
    kGLTrackingModeStandardAndSignificant
} GLTrackingMode;

typedef enum {
    kGLLoggingModeAllData,
    kGLLoggingModeOnlyLatest,
    kGLLoggingModeOwntracks
} GLLoggingMode;

typedef enum {
    kGLLocationPropertyTimestamp,
    kGLLocationPropertyLatitude,
    kGLLocationPropertyLongitude,
    kGLLocationPropertyAccuracy,
    kGLLocationPropertySpeed,
    kGLLocationPropertyAltitude,
    kGLLocationPropertyBattery
} GLLocationProperty;

typedef void (^CaseBlock)(void);

@interface GLManager : NSObject <CLLocationManagerDelegate, UNUserNotificationCenterDelegate>

+ (GLManager *)sharedManager;

+ (NSString *)currentWifiHotSpotName;

@property (strong, nonatomic, readonly) CLLocationManager *locationManager;
@property (strong, nonatomic, readonly) CMMotionActivityManager *motionActivityManager;

@property (strong, nonatomic) NSNumber *sendingInterval;
@property BOOL pausesAutomatically;
@property BOOL includeTrackingStats;
@property BOOL notificationsEnabled;
@property (nonatomic) CLLocationDistance resumesAfterDistance;
@property (nonatomic) CLLocationDistance discardPointsWithinDistance;
@property (nonatomic) int discardPointsWithinSeconds;
@property (nonatomic) GLTrackingMode trackingMode;
@property BOOL visitTrackingEnabled;
@property (nonatomic) GLLoggingMode loggingMode;
@property (nonatomic) BOOL showBackgroundLocationIndicator;
@property (nonatomic) CLActivityType activityType;
@property (nonatomic) CLLocationAccuracy desiredAccuracy;
@property (nonatomic) int pointsPerBatch;

@property (readonly) BOOL trackingEnabled;
@property (readonly) BOOL sendInProgress;
@property (strong, nonatomic, readonly) CLLocation *lastLocation;
@property (strong, nonatomic, readonly) NSDictionary *lastLocationDictionary;
@property (strong, nonatomic, readonly) CMMotionActivity *lastMotion;
@property (strong, nonatomic, readonly) NSString *lastMotionString;
@property (strong, nonatomic, readonly) NSNumber *lastStepCount;
@property (strong, nonatomic, readonly) NSDate *lastSentDate;
@property (strong, nonatomic, readonly) NSString *lastLocationName;
/* Outcome of the most recent send attempt, success or failure, for display on
   the main screen. Failures were previously only visible as a notification. */
@property (strong, nonatomic, readonly) NSDate *lastSendAttemptDate;
@property (strong, nonatomic, readonly) NSString *lastSendStatus;

- (void)startAllUpdates;
- (void)stopAllUpdates;
- (void)refreshLocation;
- (void)deleteAllData;

- (NSString *)authorizationStatusAsString;
- (void)requestAuthorizationPermission;

- (void)saveNewAPIEndpoint:(NSString *)endpoint andAccessToken:(NSString *)accessToken;
- (NSString *)apiEndpointURL;
- (NSString *)apiAccessToken;
- (NSString *)authorizationHeaderState;
- (void)saveNewDeviceId:(NSString *)deviceId;
- (NSString *)deviceId;

- (void)logAction:(NSString *)action;
- (void)sendQueueNow;
- (void)notify:(NSString *)message withTitle:(NSString *)title;

- (void)numberOfLocationsInQueue:(void(^)(long num))callback;
- (void)numberOfObjectsInQueue:(void(^)(long locations, long trips, long stats))callback;
- (void)accountInfo:(void(^)(NSString *name))block;
- (NSSet <__kindof CLRegion *>*)monitoredRegions;

- (void)requestNotificationPermission;

@property (strong, nonatomic, readonly) NSString *wifiZoneName;
@property (strong, nonatomic, readonly) NSString *wifiZoneLatitude;
@property (strong, nonatomic, readonly) NSString *wifiZoneLongitude;
- (void)saveNewWifiZone:(NSString *)name withLatitude:(NSString *)latitude andLongitude:(NSString *)longitude;

#pragma mark -

- (void)applicationWillTerminate;
- (void)applicationDidEnterBackground;
- (void)applicationWillResignActive;

@end
