//
//  GLManager.m
//  GPSLogger
//
//  Created by Aaron Parecki on 9/17/15.
//  Copyright © 2015 Esri. All rights reserved.
//  Copyright © 2017 Aaron Parecki. All rights reserved.
//

#import "GLManager.h"
#import "BakedConfig.h"
#import "GLEndpoints.h"
#import "AFHTTPSessionManager.h"
#import "LOLDatabase.h"
#import "SystemConfiguration/CaptiveNetwork.h"
@import UserNotifications;

@interface GLManager()

@property (strong, nonatomic) CLLocationManager *locationManager;
@property (strong, nonatomic) CMMotionActivityManager *motionActivityManager;

@property BOOL trackingEnabled;
@property BOOL sendInProgress;
@property BOOL batchInProgress;
@property (strong, nonatomic) CLLocation *lastLocation;
@property (strong, nonatomic) CMMotionActivity *lastMotion;
@property (strong, nonatomic) NSDate *lastSentDate;
@property (strong, nonatomic) NSString *lastLocationName;
@property (strong, nonatomic) NSDate *lastSendAttemptDate;
@property (strong, nonatomic) NSString *lastSendStatus;

@property (strong, nonatomic) NSDictionary *lastLocationDictionary;

@property (strong, nonatomic) LOLDatabase *db;

@property (strong, nonatomic) NSDate *lastScheduledNotificationDate;

@end

@implementation GLManager

static NSString *const GLLocationQueueName = @"GLLocationQueue";

NSNumber *_sendingInterval;
long _currentPointsInQueue;
NSString *_deviceId;
AFHTTPSessionManager *_httpClient;

const double FEET_TO_METERS = 0.304;
const double MPH_to_METERSPERSECOND = 0.447;

+ (GLManager *)sharedManager {
    static GLManager *_instance = nil;
    
    @synchronized (self) {
        if (_instance == nil) {
            _instance = [[self alloc] init];
            
            _instance.db = [[LOLDatabase alloc] initWithPath:[self cacheDatabasePath]];
            _instance.db.serializer = ^(id object){
                return [self dataWithJSONObject:object error:NULL];
            };
            _instance.db.deserializer = ^(NSData *data) {
                return [self objectFromJSONData:data error:NULL];
            };
            
            [_instance setupHTTPClient];
            [_instance applyBakedConfiguration];
            [_instance migrateTrackingDefaultsIfNeeded];
            [_instance restoreTrackingState];
            [_instance initializeNotifications];
        }
    }
    
    return _instance;
}

#pragma mark - GLManager control (public)

- (void)saveNewAPIEndpoint:(NSString *)endpoint andAccessToken:(NSString *)accessToken {
    [[NSUserDefaults standardUserDefaults] setObject:endpoint forKey:GLAPIEndpointDefaultsName];
    [[NSUserDefaults standardUserDefaults] setObject:accessToken forKey:GLAPIAccessTokenDefaultsName];
    [self setupHTTPClient];
}

- (NSString *)apiEndpointURL {
    return [[NSUserDefaults standardUserDefaults] stringForKey:GLAPIEndpointDefaultsName];
}

- (NSString *)apiAccessToken {
    return [[NSUserDefaults standardUserDefaults] stringForKey:GLAPIAccessTokenDefaultsName];
}

- (void)saveNewDeviceId:(NSString *)deviceId {
    _deviceId = deviceId;
    [[NSUserDefaults standardUserDefaults] setObject:deviceId forKey:GLDeviceIdDefaultsName];
    // Always call saveNewAPIEndpoint after saveNewDeviceId to synchronize changes
}

- (NSString *)deviceId {
    NSString *d = [[NSUserDefaults standardUserDefaults] stringForKey:GLDeviceIdDefaultsName];
    if(d == nil) {
        d = @"";
    }
    return d;
}

- (void)startAllUpdates {
    [self enableTracking];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:GLTrackingStateDefaultsName];
}

- (void)stopAllUpdates {
    [self disableTracking];
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:GLTrackingStateDefaultsName];
}

- (void)refreshLocation {
    NSLog(@"Trying to update location now");
    [self.locationManager stopUpdatingLocation];
    [self.locationManager performSelector:@selector(startUpdatingLocation) withObject:nil afterDelay:1.0];
}

// Every send attempt ends here so the main screen can show what happened.
// Failures used to only produce a notification, which is gone by the time the
// app is opened to find out why the queue is not draining.
- (void)recordSendResult:(NSString *)status {
    self.lastSendAttemptDate = NSDate.date;
    self.lastSendStatus = status;
    NSLog(@"Send result: %@", status);
}

- (void)sendQueueNow {
    NSMutableSet *syncedUpdates = [NSMutableSet set];
    NSMutableArray *locationUpdates = [NSMutableArray array];
    
    NSString *endpoint = [[NSUserDefaults standardUserDefaults] stringForKey:GLAPIEndpointDefaultsName];
    
    if(endpoint == nil) {
        NSLog(@"No API endpoint is set, not sending data");
        return;
    }
    
    __block long _numInQueue = 0;
    
    [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
        
        [accessor enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *object) {
            if(key && object) {
                [syncedUpdates addObject:key];
                [locationUpdates addObject:object];
            } else if(key) {
                // Remove nil objects
                [accessor removeDictionaryForKey:key];
            }
            return (BOOL)(locationUpdates.count >= self.pointsPerBatchCurrentValue);
        }];
        
        [accessor countObjectsUsingBlock:^(long num) {
            _numInQueue = num;
        }];
    }];
    
    NSMutableDictionary *postData;
    
    if(self.loggingModeCurrentValue == kGLLoggingModeOwntracks) {
        postData = locationUpdates[0];
    } else {
        postData = [NSMutableDictionary dictionaryWithDictionary:@{@"locations": locationUpdates}];
        
        // If there are still more in the queue, then send the current location as a separate property.
        // This allows the server to know where the user is immediately even if there are many thousands of points in the backlog.
        NSDictionary *currentLocation = [self currentDictionaryFromLocation:self.lastLocation];
        if(_numInQueue > self.pointsPerBatchCurrentValue && self.lastLocation) {
            [postData setObject:currentLocation forKey:@"current"];
        }
    }
    
    // If there are any template strings in the URL, replace the values with the data from the most recent location
    // TS, LAT, LON, ACC, SPD, ALT, BAT
    NSMutableString *endpointURL = [endpoint mutableCopy];
    [endpointURL replaceOccurrencesOfString:@"%TS"
                                 withString:[self stringForProperty:kGLLocationPropertyTimestamp ofLocation:self.lastLocation] options:NSLiteralSearch
                                      range:NSMakeRange(0, endpointURL.length)];
    [endpointURL replaceOccurrencesOfString:@"%LAT"
                                 withString:[self stringForProperty:kGLLocationPropertyLatitude ofLocation:self.lastLocation] options:NSLiteralSearch
                                      range:NSMakeRange(0, endpointURL.length)];
    [endpointURL replaceOccurrencesOfString:@"%LON"
                                 withString:[self stringForProperty:kGLLocationPropertyLongitude ofLocation:self.lastLocation] options:NSLiteralSearch
                                      range:NSMakeRange(0, endpointURL.length)];
    [endpointURL replaceOccurrencesOfString:@"%ACC"
                                 withString:[self stringForProperty:kGLLocationPropertyAccuracy ofLocation:self.lastLocation] options:NSLiteralSearch
                                      range:NSMakeRange(0, endpointURL.length)];
    [endpointURL replaceOccurrencesOfString:@"%SPD"
                                 withString:[self stringForProperty:kGLLocationPropertySpeed ofLocation:self.lastLocation] options:NSLiteralSearch
                                      range:NSMakeRange(0, endpointURL.length)];
    [endpointURL replaceOccurrencesOfString:@"%ALT"
                                 withString:[self stringForProperty:kGLLocationPropertyAltitude ofLocation:self.lastLocation] options:NSLiteralSearch
                                      range:NSMakeRange(0, endpointURL.length)];
    [endpointURL replaceOccurrencesOfString:@"%BAT"
                                 withString:[self stringForProperty:kGLLocationPropertyBattery ofLocation:self.lastLocation] options:NSLiteralSearch
                                      range:NSMakeRange(0, endpointURL.length)];

    
    NSLog(@"Endpoint: %@", endpointURL);
    NSLog(@"Updates in post: %lu", (unsigned long)locationUpdates.count);
    
    if(locationUpdates.count == 0) {
        self.batchInProgress = NO;
        return;
    }
    
    [self sendingStarted];
    
    [_httpClient POST:endpointURL parameters:postData headers:NULL progress:NULL success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        NSLog(@"Response: %@", responseObject);
        
        bool requestWasSuccessfullySent = NO;
        if(self.shouldConsiderHTTP200Success) {
            // Any non-200 response would have been caught by the error callback instead
            requestWasSuccessfullySent = YES;
        } else {
            // Response must be JSON
            if(![responseObject respondsToSelector:@selector(objectForKey:)]) {
                self.batchInProgress = NO;
                [self recordSendResult:@"server did not return JSON"];
                [self notify:@"Server did not return a JSON object" withTitle:@"Server Error"];
                [self sendingFinished];
                return;
            }

            // Response JSON must include {"result":"ok"}
            requestWasSuccessfullySent = [responseObject objectForKey:@"result"] && [[responseObject objectForKey:@"result"] isEqualToString:@"ok"];
        }
        
        
        if(requestWasSuccessfullySent) {
            self.lastSentDate = NSDate.date;
            [self recordSendResult:[NSString stringWithFormat:@"sent %lu", (unsigned long)locationUpdates.count]];
            NSDictionary *geocode = [responseObject objectForKey:@"geocode"];
            if(geocode && ![geocode isEqual:[NSNull null]]) {
                self.lastLocationName = [geocode objectForKey:@"full_name"];
            } else {
                self.lastLocationName = @"";
            }
            
            [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
                for(NSString *key in syncedUpdates) {
                    [accessor removeDictionaryForKey:key];
                }
            }];

            [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
                [accessor countObjectsUsingBlock:^(long num) {
                    _currentPointsInQueue = num;
                    NSLog(@"Number remaining: %ld", num);
                    if(num >= self.pointsPerBatchCurrentValue) {
                        self.batchInProgress = YES;
                    } else {
                        self.batchInProgress = NO;
                    }
                }];

                [self sendingFinished];
            }];

            [self updateSettingsFromResponse:responseObject];
        } else {
            
            self.batchInProgress = NO;
            
            if([responseObject objectForKey:@"error"]) {
                [self recordSendResult:[NSString stringWithFormat:@"%@", [responseObject objectForKey:@"error"]]];
                [self notify:[responseObject objectForKey:@"error"] withTitle:@"Server Error"];
            } else {
                [self recordSendResult:@"server did not acknowledge the data"];
                [self notify:@"Server did not acknowledge the data was received, and did not return an error message" withTitle:@"Server Error"];
            }

            [self sendingFinished];
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        self.batchInProgress = NO;
        [self recordSendResult:error.localizedDescription];
        [self notify:error.localizedDescription withTitle:@"HTTP Error"];
        [self sendingFinished];
    }];
    
}

- (void)updateSettingsFromResponse:(id _Nullable)responseObject {
    NSDictionary *settings = [responseObject objectForKey:@"set"];
    if(settings == nil) {
        return;
    }
    
    if(![settings respondsToSelector:@selector(objectForKey:)]) {
        return;
    }
    
    NSLog(@"Settings %@", settings);
    
    NSDictionary *sendIntervalBlocks = @{
        @"1s": ^{ self.sendingInterval = @1; },
        @"5s": ^{ self.sendingInterval = @5; },
        @"10s": ^{ self.sendingInterval = @10; },
        @"15s": ^{ self.sendingInterval = @15; },
        @"30s": ^{ self.sendingInterval = @30; },
        @"1m": ^{ self.sendingInterval = @60; },
        @"2m": ^{ self.sendingInterval = @120; },
        @"5m": ^{ self.sendingInterval = @300; },
        @"10m": ^{ self.sendingInterval = @600; },
        @"30m": ^{ self.sendingInterval = @1800; },
        @"off": ^{ self.sendingInterval = @0; },
    };
    [self runBlock:sendIntervalBlocks fromDictionary:settings forKey:@"send_interval"];

    NSDictionary *main = [settings objectForKey:@"main"];
    if(main != nil) {
        
        NSDictionary *trackingModeBlocks = @{
            @"off": ^{ self.trackingMode = kGLTrackingModeOff; },
            @"standard": ^{ self.trackingMode = kGLTrackingModeStandard; },
            @"significant": ^{ self.trackingMode = kGLTrackingModeSignificant; },
            @"both": ^{ self.trackingMode = kGLTrackingModeStandardAndSignificant; },
        };
        [self runBlock:trackingModeBlocks fromDictionary:main forKey:@"tracking_mode"];

        if([main objectForKey:@"visit_tracking"] != nil) {
            self.visitTrackingEnabled = [[main objectForKey:@"visit_tracking"] boolValue];
        }
        
        NSDictionary *desiredAccuracyBlocks = @{
            @"nav": ^{ self.desiredAccuracy = kCLLocationAccuracyBestForNavigation; },
            @"best": ^{ self.desiredAccuracy = kCLLocationAccuracyBest; },
            @"10m": ^{ self.desiredAccuracy = kCLLocationAccuracyNearestTenMeters; },
            @"100m": ^{ self.desiredAccuracy = kCLLocationAccuracyHundredMeters; },
            @"1km": ^{ self.desiredAccuracy = kCLLocationAccuracyKilometer; },
            @"3km": ^{ self.desiredAccuracy = kCLLocationAccuracyThreeKilometers; },
        };
        [self runBlock:desiredAccuracyBlocks fromDictionary:main forKey:@"desired_accuracy"];

        NSDictionary *activityTypeBlocks = @{
            @"other": ^{ self.activityType = CLActivityTypeOther; },
            @"car": ^{ self.activityType = CLActivityTypeAutomotiveNavigation; },
            @"fitness": ^{ self.activityType = CLActivityTypeFitness; },
            @"nav": ^{ self.activityType = CLActivityTypeOtherNavigation; },
            @"air": ^{ self.activityType = CLActivityTypeAirborne; },
        };
        [self runBlock:activityTypeBlocks fromDictionary:main forKey:@"activity_type"];

        if([main objectForKey:@"background_indicator"] != nil) {
            self.showBackgroundLocationIndicator = [[main objectForKey:@"background_indicator"] boolValue];
        }

        if([main objectForKey:@"pause_automatically"] != nil) {
            self.pausesAutomatically = [[main objectForKey:@"pause_automatically"] boolValue];
        }

        NSDictionary *loggingModeBlocks = @{
            @"all": ^{ self.loggingMode = kGLLoggingModeAllData; },
            @"latest": ^{ self.loggingMode = kGLLoggingModeOnlyLatest; },
            @"owntracks": ^{ self.loggingMode = kGLLoggingModeOwntracks; },
        };
        [self runBlock:loggingModeBlocks fromDictionary:main forKey:@"logging_mode"];
        
        NSDictionary *batchSizeBlocks = @{
            @50: ^{ self.pointsPerBatch = 50; },
            @100: ^{ self.pointsPerBatch = 100; },
            @200: ^{ self.pointsPerBatch = 200; },
            @500: ^{ self.pointsPerBatch = 500; },
            @1000: ^{ self.pointsPerBatch = 1000; },
        };
        [self runBlock:batchSizeBlocks fromDictionary:main forKey:@"batch_size"];

        NSDictionary *resumeWithGeofenceBlocks = @{
            @"off": ^{ self.resumesAfterDistance = -1; },
            @"100m": ^{ self.resumesAfterDistance = 100; },
            @"200m": ^{ self.resumesAfterDistance = 200; },
            @"500m": ^{ self.resumesAfterDistance = 500; },
            @"1km": ^{ self.resumesAfterDistance = 1000; },
            @"2km": ^{ self.resumesAfterDistance = 2000; },
        };
        [self runBlock:resumeWithGeofenceBlocks fromDictionary:main forKey:@"resume_with_geofence"];

        NSDictionary *minDistanceBlocks = @{
            @"off": ^{ self.discardPointsWithinDistance = -1; },
            @"1m": ^{ self.discardPointsWithinDistance = 1; },
            @"10m": ^{ self.discardPointsWithinDistance = 10; },
            @"50m": ^{ self.discardPointsWithinDistance = 50; },
            @"100m": ^{ self.discardPointsWithinDistance = 100; },
            @"500m": ^{ self.discardPointsWithinDistance = 500; },
        };
        [self runBlock:minDistanceBlocks fromDictionary:main forKey:@"min_distance"];

        NSDictionary *minTimeBlocks = @{
            @"1s": ^{ self.discardPointsWithinSeconds = 1; },
            @"5s": ^{ self.discardPointsWithinSeconds = 5; },
            @"10s": ^{ self.discardPointsWithinSeconds = 10; },
            @"30s": ^{ self.discardPointsWithinSeconds = 30; },
            @"1m": ^{ self.discardPointsWithinSeconds = 60; },
            @"5m": ^{ self.discardPointsWithinSeconds = 300; },
        };
        [self runBlock:minTimeBlocks fromDictionary:main forKey:@"min_time"];

    }

    [[NSNotificationCenter defaultCenter] postNotificationName:GLSettingsChangedNotification object:self];
}

- (void)runBlock:(NSDictionary *)blocks fromDictionary:(NSDictionary *)dictionary forKey:(NSString *)key {
    NSString *property = [dictionary objectForKey:key];
    if([property respondsToSelector:@selector(isEqualToString:)]) {
        if([blocks objectForKey:property] != nil) {
            ((CaseBlock)blocks[property])();
        }
    }
}

- (NSString *)stringForProperty:(GLLocationProperty)prop ofLocation:(CLLocation *)location {
    NSString *string;
    switch(prop) {
        case kGLLocationPropertyTimestamp:
            string = [GLManager iso8601DateStringFromDate:location.timestamp];
            break;
        case kGLLocationPropertyLatitude:
            string = [[NSNumber numberWithDouble:((int)(location.coordinate.latitude * 10000000)) / 10000000.0] stringValue];
            break;
        case kGLLocationPropertyLongitude:
            string = [[NSNumber numberWithDouble:((int)(location.coordinate.longitude * 10000000)) / 10000000.0] stringValue];
            break;
            
        case kGLLocationPropertyAccuracy:
            string = [[NSNumber numberWithInt:(int)round(location.horizontalAccuracy)] stringValue];
            break;
        case kGLLocationPropertySpeed:
            string = [[NSNumber numberWithInt:(int)round(location.speed)] stringValue];
            break;
        case kGLLocationPropertyAltitude:
            string = [[NSNumber numberWithInt:(int)round(location.altitude)] stringValue];
            break;
        case kGLLocationPropertyBattery:
            string = [[self currentBatteryLevel] stringValue];
            break;
    }
    return string;
}

- (void)logAction:(NSString *)action {
    if(!self.includeTrackingStats) {
        return;
    }

    [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
        NSString *timestamp = [GLManager iso8601DateStringFromDate:[NSDate date]];
        NSMutableDictionary *update = [NSMutableDictionary dictionaryWithDictionary:@{
                                                                                      @"type": @"Feature",
                                                                                      @"properties": [NSMutableDictionary dictionaryWithDictionary:@{
                                                                                              @"timestamp": timestamp,
                                                                                              @"action": action,
                                                                                              }]
                                                                                      }];
        [self addMetadataToUpdate:update];
        
        if(self.lastLocation) {
            [update setObject:@{
                                @"type": @"Point",
                                @"coordinates": @[
                                        [NSNumber numberWithDouble:self.lastLocation.coordinate.longitude],
                                        [NSNumber numberWithDouble:self.lastLocation.coordinate.latitude]
                                        ]
                                } forKey:@"geometry"];
        }
        [accessor setDictionary:update forKey:[NSString stringWithFormat:@"%@-log", timestamp]];
    }];
}

- (void)accountInfo:(void(^)(NSString *name))block {
    NSString *endpoint = [[NSUserDefaults standardUserDefaults] stringForKey:GLAPIEndpointDefaultsName];
    [_httpClient GET:endpoint parameters:nil headers:nil progress:NULL success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        NSDictionary *dict = (NSDictionary *)responseObject;
        block((NSString *)[dict objectForKey:@"name"]);
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSLog(@"Failed to get account info");
    }];
}

- (void)numberOfLocationsInQueue:(void(^)(long num))callback {
    [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
        [accessor countObjectsUsingBlock:^(long num) {
            _currentPointsInQueue = num;
            callback(num);
        }];
    }];
}

- (void)numberOfObjectsInQueue:(void(^)(long locations, long trips, long stats))callback {
    [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
        __block long locations = 0;
        __block long trips = 0;
        __block long stats = 0;
        [accessor enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *object) {
            NSDictionary *properties = [object objectForKey:@"properties"];
            if([properties objectForKey:@"action"]) {
                stats++;
            } else if([[properties objectForKey:@"type"] isEqualToString:@"trip"]) {
                trips++;
            } else {
                locations++;
            }
            return NO;
        }];
        //NSLog(@"Queue stats: %ld %ld %ld", locations, trips, stats);
        callback(locations, trips, stats);
    }];
}


- (void)requestAuthorizationPermission {
    bool isFirstRequest = false;
    if (@available(iOS 14.0, *)) {
        if(self.locationManager.authorizationStatus == kCLAuthorizationStatusNotDetermined) {
            isFirstRequest = true;
        }
    }
    if(isFirstRequest) {
        NSLog(@"Requesting WhenInUse Permission");
        [self.locationManager requestWhenInUseAuthorization];
    } else {
        NSLog(@"Requesting Always Permission");
        [self.locationManager requestAlwaysAuthorization];
    }
}


#pragma mark - GLManager control (private)

- (void)setupHTTPClient {
    NSURL *endpoint = [NSURL URLWithString:[[NSUserDefaults standardUserDefaults] stringForKey:GLAPIEndpointDefaultsName]];
    
    if(endpoint) {
        _httpClient = [[AFHTTPSessionManager manager] initWithBaseURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@://%@", endpoint.scheme, endpoint.host]]];
        _httpClient.requestSerializer = [AFJSONRequestSerializer serializer];
        _httpClient.responseSerializer = [AFJSONResponseSerializer serializer];
        if(self.apiAccessToken != nil && ![@"" isEqualToString:self.apiAccessToken]) {
            if(self.loggingModeCurrentValue == kGLLoggingModeOwntracks) {
                [_httpClient.requestSerializer setValue:[NSString stringWithFormat:@"Basic %@:", self.apiAccessToken]
                                     forHTTPHeaderField:@"Authorization"];
            } else {
                [_httpClient.requestSerializer setValue:[NSString stringWithFormat:@"Bearer %@", self.apiAccessToken]
                                     forHTTPHeaderField:@"Authorization"];
            }
        } else {
            [_httpClient.requestSerializer setValue:nil forHTTPHeaderField:@"Authorization"];
        }
    }
    
    _deviceId = [self deviceId];
}

/* What the HTTP client will actually put on the wire, masked. The stored token
   and the client's header are two different things — the server logging
   `auth=none` while Settings showed a populated token field is exactly the
   confusion this exists to end, so the launch diagnostic reports the header
   itself rather than the defaults value it was supposed to come from. */
- (NSString *)authorizationHeaderState {
    if(_httpClient == nil) {
        return @"no HTTP client";
    }
    NSString *header = [_httpClient.requestSerializer valueForHTTPHeaderField:@"Authorization"];
    if(header.length == 0) {
        return @"MISSING";
    }
    NSUInteger shown = MIN((NSUInteger)13, header.length);
    return [NSString stringWithFormat:@"%@…", [header substringToIndex:shown]];
}

- (void)applyBakedConfiguration {
    // Single-user app: the endpoint and token are compiled in (BakedConfig.h,
    // written by CI from the DROP_TOKEN secret). Force the stored values to
    // match on every launch rather than only filling them when empty, so the
    // config can't drift, be edited by accident, or be lost by a reinstall.
    //
    // saveNewAPIEndpoint:andAccessToken: is used deliberately instead of
    // writing NSUserDefaults directly: it re-runs setupHTTPClient, which is
    // what rebuilds the AFHTTPSessionManager and its Authorization header. A
    // raw defaults write would leave the already-built client on the old token.
    if([GL_BAKED_TOKEN isEqualToString:@"NO_TOKEN_BAKED_IN"]) {
        // Local/simulator build with no secret available. Overwriting here
        // would wipe a good config on a dev build, so leave it be.
        NSLog(@"Baked config: placeholder token, leaving stored config alone");
        return;
    }

    NSString *bakedEndpoint = GLEndpointURL(@"/overland").absoluteString;
    NSString *endpoint = [[NSUserDefaults standardUserDefaults] stringForKey:GLAPIEndpointDefaultsName];
    NSString *token = [[NSUserDefaults standardUserDefaults] stringForKey:GLAPIAccessTokenDefaultsName];
    if([bakedEndpoint isEqualToString:endpoint] && [GL_BAKED_TOKEN isEqualToString:token]) {
        return;
    }

    NSLog(@"Baked config: forcing endpoint=%@ and baked access token (was endpoint=%@ token=%@)",
          bakedEndpoint, endpoint, token.length > 0 ? @"set" : @"empty");
    [self saveNewAPIEndpoint:bakedEndpoint andAccessToken:GL_BAKED_TOKEN];
}

- (void)migrateTrackingDefaultsIfNeeded {
    if([self defaultsKeyExists:GLMigratedToSignificantV1DefaultsName]) {
        return;
    }

    // Commit 9ca17b6 changed the *defaults* for tracking mode and visit
    // monitoring, which only take effect when the NSUserDefaults key is absent.
    // A phone that had already run an older build had Standard mode written into
    // defaults, so it kept the GPS running continuously (~6,000 points queued)
    // even on the new build. Force the new values once, keyed off a migration
    // flag rather than off the mode itself, so a mode chosen manually after this
    // runs is left alone.
    NSLog(@"Migrating tracking defaults to significant-change + visit monitoring");
    self.trackingMode = kGLTrackingModeSignificant;
    self.visitTrackingEnabled = YES;

    // The setters above no-op when the value already matches, which on a fresh
    // install leaves the keys absent. Write them explicitly so the persisted
    // state matches what the migration decided.
    [[NSUserDefaults standardUserDefaults] setInteger:kGLTrackingModeSignificant forKey:GLSignificantLocationModeDefaultsName];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:GLVisitTrackingEnabledDefaultsName];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:GLMigratedToSignificantV1DefaultsName];
}

- (void)restoreTrackingState {
    if([[NSUserDefaults standardUserDefaults] boolForKey:GLTrackingStateDefaultsName]) {
        [self enableTracking];
    } else {
        [self disableTracking];
    }
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    [[NSNotificationCenter defaultCenter] postNotificationName:GLAuthorizationStatusChangedNotification object:self];
    NSLog(@"Location Authorization Changed: %@", self.authorizationStatusAsString);

    // BUG FIX: startUpdatingLocation gets called while authorization is still
    // "Not Determined" (on first launch / auto-enable), and iOS then delivers
    // NO locations even after the user grants permission — the manager sits
    // authorized but idle. So when authorization flips to granted and tracking
    // is on, re-run enableTracking to actually (re)start location delivery.
    CLAuthorizationStatus status = manager.authorizationStatus;
    BOOL authorized = (status == kCLAuthorizationStatusAuthorizedWhenInUse ||
                       status == kCLAuthorizationStatusAuthorizedAlways);
    if (authorized &&
        [[NSUserDefaults standardUserDefaults] boolForKey:GLTrackingStateDefaultsName]) {
        NSLog(@"Authorization granted — (re)starting location updates");
        [self enableTracking];
        // With WhenInUse we can still request the Always upgrade for background.
        if (status == kCLAuthorizationStatusAuthorizedWhenInUse) {
            [manager requestAlwaysAuthorization];
        }
    }
}

- (void)enableTracking {
    self.trackingEnabled = YES;

    self.locationManager.activityType = self.activityType;
    self.locationManager.desiredAccuracy = self.desiredAccuracy;
    self.locationManager.showsBackgroundLocationIndicator = self.showBackgroundLocationIndicator;
    self.locationManager.pausesLocationUpdatesAutomatically = self.pausesAutomatically;

    switch(self.trackingMode) {
        case kGLTrackingModeOff:
            NSLog(@"Not monitoring continuous location");
            [self.locationManager stopUpdatingLocation];
            [self.locationManager stopUpdatingHeading];
            [self.locationManager stopMonitoringSignificantLocationChanges];
            break;
        case kGLTrackingModeStandard:
            NSLog(@"Monitoring standard location changes");
            [self.locationManager startUpdatingLocation];
            [self.locationManager startUpdatingHeading];
            [self.locationManager stopMonitoringSignificantLocationChanges];
            break;
        case kGLTrackingModeSignificant:
            NSLog(@"Monitoring significant location changes");
            [self.locationManager startMonitoringSignificantLocationChanges];
            [self.locationManager stopUpdatingLocation];
            [self.locationManager stopUpdatingHeading];
            break;
        case kGLTrackingModeStandardAndSignificant:
            NSLog(@"Monitoring both standard and significant location changes");
            [self.locationManager startUpdatingLocation];
            [self.locationManager startUpdatingHeading];
            [self.locationManager startMonitoringSignificantLocationChanges];
            break;
    }

    if(self.visitTrackingEnabled) {
        [self.locationManager startMonitoringVisits];
    } else {
        [self.locationManager stopMonitoringVisits];
    }
    
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    
    if(CMMotionActivityManager.isActivityAvailable) {
        [self.motionActivityManager startActivityUpdatesToQueue:[NSOperationQueue mainQueue] withHandler:^(CMMotionActivity *activity) {
            self.lastMotion = activity;
            [[NSNotificationCenter defaultCenter] postNotificationName:GLNewActivityNotification object:self];
        }];
    }

    NSLog(@"Location Authorization Status %@", self.authorizationStatusAsString);
    
    // Set the last location if location manager has a last location.
    // This will be set for example when the app launches due to a signification location change,
    // the locationmanager has a location already before a location event is delivered to the delegate.
    if(self.locationManager.location) {
        self.lastLocation = self.locationManager.location;
    }
    
    [self scheduleLocalNotification];
}

- (void)disableTracking {
    self.trackingEnabled = NO;
    [UIDevice currentDevice].batteryMonitoringEnabled = NO;
    [self.locationManager stopMonitoringVisits];
    [self.locationManager stopUpdatingHeading];
    [self.locationManager stopUpdatingLocation];
    [self.locationManager stopMonitoringSignificantLocationChanges];
    if(CMMotionActivityManager.isActivityAvailable) {
        [self.motionActivityManager stopActivityUpdates];
        self.lastMotion = nil;
    }
    [self cancelLocalNotification];
}

- (void)sendingStarted {
    self.sendInProgress = YES;
    [[NSNotificationCenter defaultCenter] postNotificationName:GLSendingStartedNotification object:self];
}

- (void)sendingFinished {
    self.sendInProgress = NO;
    [[NSNotificationCenter defaultCenter] postNotificationName:GLSendingFinishedNotification object:self];
}

- (void)sendQueueIfTimeElapsed {
    BOOL sendingEnabled = [self.sendingInterval integerValue] > -1;
    if(!sendingEnabled) {
        return;
    }
    
    if(self.sendInProgress) {
        NSLog(@"Send is already in progress");
        return;
    }
    
    // BUG FIX: on a fresh install lastSentDate is nil, and [nil compare:date]
    // returns NSOrderedSame (0), not NSOrderedAscending — so timeElapsed was
    // false forever and the very first batch never sent (the app relied on the
    // user tapping "Send Now" once to seed lastSentDate). Treat nil as elapsed.
    BOOL timeElapsed = (self.lastSentDate == nil) ||
        [(NSDate *)[self.lastSentDate dateByAddingTimeInterval:[self.sendingInterval doubleValue]] compare:NSDate.date] == NSOrderedAscending;

    // Send if time has elapsed,
    // or if we're in the middle of flushing
    if(timeElapsed || self.batchInProgress) {
        NSLog(@"Sending a batch now");
        [self sendQueueNow];
        self.lastSentDate = NSDate.date;
    }
}

- (void)sendQueueIfNotInProgress {
    if(self.sendInProgress) {
        return;
    }
    
    [self sendQueueNow];
    self.lastSentDate = NSDate.date;
}

#pragma mark - Scheduled local notifications

- (void)scheduleLocalNotification {
    // Schedule a local notification for 10 minutes into the future to remind the user to launch the app.
    // We'll cancel the notification when we get an update from the system, so this should only
    // run if the app is shut down for some reason.
    
    int scheduleRateLimit = 60;
    int reminderIntervalSeconds = 600;
    
    // Only do this at most once a minute so we don't hammer the system with scheduled notification requests
    NSDate *lastScheduled = self.lastScheduledNotificationDate;
    if(lastScheduled != nil && [lastScheduled timeIntervalSinceNow] > -1 * scheduleRateLimit) {
        return;
    }
    
    [self cancelLocalNotification];
    
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = [NSString localizedUserNotificationStringForKey:@"Overland" arguments:nil];
    content.body = [NSString localizedUserNotificationStringForKey:@"Location updates were stopped. Launch the app to resume."
                arguments:nil];
    content.sound = [UNNotificationSound defaultSound];
    
    UNTimeIntervalNotificationTrigger* trigger = [UNTimeIntervalNotificationTrigger
                triggerWithTimeInterval:reminderIntervalSeconds repeats:NO];
    UNNotificationRequest* request = [UNNotificationRequest requestWithIdentifier:@"reminder"
                content:content trigger:trigger];
     
    UNUserNotificationCenter* center = [UNUserNotificationCenter currentNotificationCenter];
    [center addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
        self.lastScheduledNotificationDate = NSDate.now;
    }];
}

- (void)cancelLocalNotification {
    UNUserNotificationCenter* center = [UNUserNotificationCenter currentNotificationCenter];
    [center removePendingNotificationRequestsWithIdentifiers:@[@"reminder"]];
}

- (NSDate *)lastScheduledNotificationDate {
    if([self defaultsKeyExists:GLLastScheduledNotificationDateDefaultsName]) {
        return (NSDate *)[[NSUserDefaults standardUserDefaults] objectForKey:GLLastScheduledNotificationDateDefaultsName];
    } else {
        return nil;
    }
}
- (void)setLastScheduledNotificationDate:(NSDate *)date {
    [[NSUserDefaults standardUserDefaults] setObject:date forKey:GLLastScheduledNotificationDateDefaultsName];
}


#pragma mark - Properties

- (CLLocationManager *)locationManager {
    if (!_locationManager) {
        _locationManager = [[CLLocationManager alloc] init];
        _locationManager.delegate = self;
        _locationManager.distanceFilter = kCLDistanceFilterNone;
        _locationManager.allowsBackgroundLocationUpdates = YES;
        _locationManager.pausesLocationUpdatesAutomatically = self.pausesAutomatically;
        _locationManager.desiredAccuracy = self.desiredAccuracy;
        _locationManager.activityType = self.activityType;
    }
    
    return _locationManager;
}

- (CMMotionActivityManager *)motionActivityManager {
    if (!_motionActivityManager) {
        _motionActivityManager = [[CMMotionActivityManager alloc] init];
    }
    
    return _motionActivityManager;
}

- (NSString *)currentBatteryState {
    switch([UIDevice currentDevice].batteryState) {
        case UIDeviceBatteryStateUnknown:
            return @"unknown";
        case UIDeviceBatteryStateCharging:
            return @"charging";
        case UIDeviceBatteryStateFull:
            return @"full";
        case UIDeviceBatteryStateUnplugged:
            return @"unplugged";
    }
}

- (NSNumber *)currentBatteryLevel {
    return [NSNumber numberWithDouble:((int)([UIDevice currentDevice].batteryLevel * 100)) / 100.0];
}

- (NSString *)authorizationStatusAsString {
    if (@available(iOS 14.0, *)) {
        switch(self.locationManager.authorizationStatus) {
            case kCLAuthorizationStatusNotDetermined:
                return @"Not Determined";
            case kCLAuthorizationStatusRestricted:
                return @"Restricted";
            case kCLAuthorizationStatusDenied:
                return @"Denied";
            case kCLAuthorizationStatusAuthorizedWhenInUse:
                return @"When in Use";
            case kCLAuthorizationStatusAuthorizedAlways:
                return @"Always";
        }
    } else {
        return @"Unknown";
    }
}

- (BOOL)shouldConsiderHTTP200Success {
    NSUserDefaults *standardUserDefaults = [NSUserDefaults standardUserDefaults];
    return [standardUserDefaults boolForKey:GLConsiderHTTP200SuccessDefaultsName];
}

- (CLLocationDistance)resumesAfterDistance {
    if([self defaultsKeyExists:GLResumesAutomaticallyDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] doubleForKey:GLResumesAutomaticallyDefaultsName];
    } else {
        return -1;
    }
}
- (void)setResumesAfterDistance:(CLLocationDistance)resumesAfterDistance {
    [[NSUserDefaults standardUserDefaults] setDouble:resumesAfterDistance forKey:GLResumesAutomaticallyDefaultsName];
}

- (CLLocationDistance)discardPointsWithinDistance {
    if([self defaultsKeyExists:GLDiscardPointsWithinDistanceDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] doubleForKey:GLDiscardPointsWithinDistanceDefaultsName];
    } else {
        return -1;
    }
}
- (void)setDiscardPointsWithinDistance:(CLLocationDistance)distance {
    [[NSUserDefaults standardUserDefaults] setDouble:distance forKey:GLDiscardPointsWithinDistanceDefaultsName];
}

- (CLLocationDistance)discardPointsWithinDistanceCurrentValue {
    return self.discardPointsWithinDistance;
}

- (int)discardPointsWithinSeconds {
    if([self defaultsKeyExists:GLDiscardPointsWithinSecondsDefaultsName]) {
        return (int)[[NSUserDefaults standardUserDefaults] integerForKey:GLDiscardPointsWithinSecondsDefaultsName];
    } else {
        return 1;
    }
}
- (void)setDiscardPointsWithinSeconds:(int)seconds {
    [[NSUserDefaults standardUserDefaults] setInteger:seconds forKey:GLDiscardPointsWithinSecondsDefaultsName];
}

- (int)discardPointsWithinSecondsCurrentValue {
    return self.discardPointsWithinSeconds;
}


#pragma mark CLLocationManager

- (NSSet *)monitoredRegions {
    return self.locationManager.monitoredRegions;
}

- (BOOL)pausesAutomatically {
    if([self defaultsKeyExists:GLPausesAutomaticallyDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] boolForKey:GLPausesAutomaticallyDefaultsName];
    } else {
        return NO;
    }
}
- (void)setPausesAutomatically:(BOOL)pausesAutomatically {
    BOOL prevValue = self.pausesAutomatically;
    if(prevValue != pausesAutomatically) {
        [[NSUserDefaults standardUserDefaults] setBool:pausesAutomatically forKey:GLPausesAutomaticallyDefaultsName];
        NSLog(@"Setting pausesLocationUpdatesAutomatically %d", pausesAutomatically);
        self.locationManager.pausesLocationUpdatesAutomatically = pausesAutomatically;
    }
}

- (BOOL)includeTrackingStats {
    if([self defaultsKeyExists:GLIncludeTrackingStatsDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] boolForKey:GLIncludeTrackingStatsDefaultsName];
    } else {
        return NO;
    }
}
- (void)setIncludeTrackingStats:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:GLIncludeTrackingStatsDefaultsName];
}

- (GLTrackingMode)trackingMode {
    if([self defaultsKeyExists:GLSignificantLocationModeDefaultsName]) {
        return (int)[[NSUserDefaults standardUserDefaults] integerForKey:GLSignificantLocationModeDefaultsName];
    } else {
        // Upstream defaults to Standard, which keeps the GPS running continuously
        // and logged ~8,400 points/day here — the reason tracking was switched off
        // on 2026-07-22. Significant-change wakes the app only after ~500m of
        // movement, which is what the day record needs: where he went, not the
        // path he took to get there.
        return kGLTrackingModeSignificant;
    }
}
- (void)setTrackingMode:(GLTrackingMode)trackingMode {
    GLTrackingMode previousTrackingMode = self.trackingMode;
    if(previousTrackingMode != trackingMode) {
        [[NSUserDefaults standardUserDefaults] setInteger:trackingMode forKey:GLSignificantLocationModeDefaultsName];
        [self enableTracking];
    }
}

- (BOOL)visitTrackingEnabled {
    if([self defaultsKeyExists:GLVisitTrackingEnabledDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] boolForKey:GLVisitTrackingEnabledDefaultsName];
    } else {
        // On by default: CLVisit is iOS's own arrival/departure detection, so it
        // gives a dwell ("at this place from 14:02 to 19:40") that a sparse point
        // stream cannot, and it costs no extra power — it rides the same
        // significant-change wakeups.
        return YES;
    }
}
- (void)setVisitTrackingEnabled:(BOOL)enabled {
    BOOL previousEnabled = self.visitTrackingEnabled;
    if(previousEnabled != enabled) {
        [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:GLVisitTrackingEnabledDefaultsName];
        [self enableTracking];
    }
}

- (GLLoggingMode)loggingMode {
    if([self defaultsKeyExists:GLLoggingModeDefaultsName]) {
        return (int)[[NSUserDefaults standardUserDefaults] integerForKey:GLLoggingModeDefaultsName];
    } else {
        return kGLLoggingModeAllData;
    }
}
- (void)setLoggingMode:(GLLoggingMode)loggingMode {
    GLLoggingMode previousLoggingMode = self.loggingMode;
    if(previousLoggingMode != loggingMode) {
        [[NSUserDefaults standardUserDefaults] setInteger:loggingMode forKey:GLLoggingModeDefaultsName];
        [self setupHTTPClient];
    }
}

- (GLLoggingMode)loggingModeCurrentValue {
    return self.loggingMode;
}

- (BOOL)showBackgroundLocationIndicator {
    if([self defaultsKeyExists:GLBackgroundIndicatorDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] boolForKey:GLBackgroundIndicatorDefaultsName];
    } else {
        return NO;
    }
}
- (void)setShowBackgroundLocationIndicator:(BOOL)mode {
    BOOL previousMode = self.showBackgroundLocationIndicator;
    if(previousMode != mode) {
        [[NSUserDefaults standardUserDefaults] setBool:mode forKey:GLBackgroundIndicatorDefaultsName];
        if(self.trackingEnabled) {
            self.locationManager.showsBackgroundLocationIndicator = mode;
        }
    }
}

- (CLActivityType)activityType {
    if([self defaultsKeyExists:GLActivityTypeDefaultsName]) {
        // Map back to CLActivityType constants
        long activityInt = [[NSUserDefaults standardUserDefaults] integerForKey:GLActivityTypeDefaultsName];
        CLActivityType activityType;
        switch(activityInt) {
            case 1:
                activityType = CLActivityTypeOther;
                break;
            case 2:
                activityType = CLActivityTypeAutomotiveNavigation;
                break;
            case 3:
                activityType = CLActivityTypeFitness;
                break;
            case 4:
                activityType = CLActivityTypeOtherNavigation;
                break;
            case 5:
                if (@available(iOS 12.0, *)) {
                    activityType = CLActivityTypeAirborne;
                } else {
                    activityType = CLActivityTypeOther;
                }
                break;
            default:
                activityType = CLActivityTypeOther;
                break;
        }
        return activityType;
    } else {
        return CLActivityTypeOther;
    }
}
- (void)setActivityType:(CLActivityType)activityType {
    // Store these as integers, in the same order as the UI control
    int activityInt;
    switch(activityType) {
        case CLActivityTypeOther:
            activityInt = 1;
            break;
        case CLActivityTypeAutomotiveNavigation:
            activityInt = 2;
            break;
        case CLActivityTypeFitness:
            activityInt = 3;
            break;
        case CLActivityTypeOtherNavigation:
            activityInt = 4;
            break;
        case CLActivityTypeAirborne:
            if (@available(iOS 12.0, *)) {
                activityInt = 5;
            } else {
                activityInt = 1;
            }
            break;
    }
    [[NSUserDefaults standardUserDefaults] setInteger:activityInt forKey:GLActivityTypeDefaultsName];
    self.locationManager.activityType = activityType;
}

- (CLLocationAccuracy)desiredAccuracy {
    if([self defaultsKeyExists:GLDesiredAccuracyDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] doubleForKey:GLDesiredAccuracyDefaultsName];
    } else {
        return kCLLocationAccuracyHundredMeters;
    }
}
- (void)setDesiredAccuracy:(CLLocationAccuracy)desiredAccuracy {
    [[NSUserDefaults standardUserDefaults] setDouble:desiredAccuracy forKey:GLDesiredAccuracyDefaultsName];
    self.locationManager.desiredAccuracy = desiredAccuracy;
}

- (int)pointsPerBatch {
    if([self defaultsKeyExists:GLPointsPerBatchDefaultsName]) {
        return (int)[[NSUserDefaults standardUserDefaults] integerForKey:GLPointsPerBatchDefaultsName];
    } else {
        return 200;
    }
}
- (void)setPointsPerBatch:(int)points {
    [[NSUserDefaults standardUserDefaults] setInteger:points forKey:GLPointsPerBatchDefaultsName];
}

- (int)pointsPerBatchCurrentValue {
    return self.pointsPerBatch;
}

#pragma mark GLManager

- (NSNumber *)sendingInterval {
    if(_sendingInterval)
        return _sendingInterval;
    
    _sendingInterval = (NSNumber *)[[NSUserDefaults standardUserDefaults] valueForKey:GLSendIntervalDefaultsName];
    if(_sendingInterval == nil) {
        _sendingInterval = [NSNumber numberWithInteger:300];
    }
    return _sendingInterval;
}

- (void)setSendingInterval:(NSNumber *)newValue {
    [[NSUserDefaults standardUserDefaults] setValue:newValue forKey:GLSendIntervalDefaultsName];
    _sendingInterval = newValue;
}

- (NSDate *)lastSentDate {
    return (NSDate *)[[NSUserDefaults standardUserDefaults] objectForKey:GLLastSentDateDefaultsName];
}

- (void)setLastSentDate:(NSDate *)lastSentDate {
    [[NSUserDefaults standardUserDefaults] setObject:lastSentDate forKey:GLLastSentDateDefaultsName];
}

// Persisted, not just held in memory: significant-change wakeups relaunch the
// process, so an in-memory status would read "none yet" every time the app is
// opened to find out why the queue is not draining.
- (NSDate *)lastSendAttemptDate {
    return (NSDate *)[[NSUserDefaults standardUserDefaults] objectForKey:GLLastSendAttemptDateDefaultsName];
}
- (void)setLastSendAttemptDate:(NSDate *)date {
    [[NSUserDefaults standardUserDefaults] setObject:date forKey:GLLastSendAttemptDateDefaultsName];
}
- (NSString *)lastSendStatus {
    return [[NSUserDefaults standardUserDefaults] stringForKey:GLLastSendStatusDefaultsName];
}
- (void)setLastSendStatus:(NSString *)status {
    [[NSUserDefaults standardUserDefaults] setObject:status forKey:GLLastSendStatusDefaultsName];
}

#pragma mark - CLLocationManager Delegate Methods

- (void)locationManager:(CLLocationManager *)manager didVisit:(CLVisit *)visit {

    if(self.visitTrackingEnabled) {
        [[NSNotificationCenter defaultCenter] postNotificationName:GLNewDataNotification object:self];
        [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
            NSString *timestamp = [GLManager iso8601DateStringFromDate:[NSDate date]];
            NSDictionary *update = @{
                                      @"type": @"Feature",
                                      @"geometry": @{
                                              @"type": @"Point",
                                              @"coordinates": @[
                                                      [NSNumber numberWithDouble:visit.coordinate.longitude],
                                                      [NSNumber numberWithDouble:visit.coordinate.latitude]
                                                      ]
                                              },
                                      @"properties": [NSMutableDictionary dictionaryWithDictionary:@{
                                              @"timestamp": timestamp,
                                              @"action": @"visit",
                                              @"arrival_date": ([visit.arrivalDate isEqualToDate:[NSDate distantPast]] ? [NSNull null] : [GLManager iso8601DateStringFromDate:visit.arrivalDate]),
                                              @"departure_date": ([visit.departureDate isEqualToDate:[NSDate distantFuture]] ? [NSNull null] : [GLManager iso8601DateStringFromDate:visit.departureDate]),
                                              @"horizontal_accuracy": [NSNumber numberWithInt:visit.horizontalAccuracy],
                                              }]
                                    };
            [self addMetadataToUpdate:update];
            [accessor setDictionary:update forKey:[NSString stringWithFormat:@"%@-visit", timestamp]];
        }];

    }

    [self sendQueueIfTimeElapsed];
}

- (void)deleteAllData {
    [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
        [accessor deleteAllData];
    }];
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray *)locations {

    // DIAG: prove whether CoreLocation is actually delivering coordinates.
    CLLocation *diagLoc = locations.lastObject;
    NSLog(@"DIAG didUpdateLocations count=%lu last=%f,%f acc=%f authStatus=%ld trackingMode=%d",
          (unsigned long)locations.count,
          diagLoc.coordinate.latitude, diagLoc.coordinate.longitude,
          diagLoc.horizontalAccuracy,
          (long)manager.authorizationStatus, (int)self.trackingMode);

    if(self.trackingMode == kGLTrackingModeOff) {
        // This probably shouldn't happen, but just in case, don't log anything if they have tracking mode set to off
        return;
    }
        
    // If a wifi override is configured, replace the input location list with the location in the wifi mapping
    if([GLManager currentWifiHotSpotName]) {
        CLLocation *wifiLocation = [self currentLocationFromWifiName:[GLManager currentWifiHotSpotName]];
        if(wifiLocation) {
            locations = @[wifiLocation];
        }
    }
    
    // NSLog(@"Received %d locations", (int)locations.count);
    
    // NSLog(@"%@", locations);
    
    NSString *activityType = @"";
    switch([GLManager sharedManager].activityType) {
        case CLActivityTypeOther:
            activityType = @"other";
            break;
        case CLActivityTypeAutomotiveNavigation:
            activityType = @"automotive_navigation";
            break;
        case CLActivityTypeFitness:
            activityType = @"fitness";
            break;
        case CLActivityTypeOtherNavigation:
            activityType = @"other_navigation";
            break;
        case CLActivityTypeAirborne:
            activityType = @"airborne";
    }
    
    CLLocation *lastLocationSeen = self.lastLocation; // Grab the last known location from the previous batch
    
    int startIndex = 0;
    if(self.loggingModeCurrentValue == kGLLoggingModeOnlyLatest || self.loggingModeCurrentValue == kGLLoggingModeOwntracks) {
        // Only grab the latest point in this batch
        startIndex = ((int)locations.count) - 1;
    }
    
    BOOL didAddData = NO;
    
    for(int i=startIndex; i<locations.count; i++) {
        CLLocation *loc = locations[i];
        
        // If Discard is enabled, check if this point is too close to the previous
        if(self.discardPointsWithinDistanceCurrentValue > 0) {
            CLLocationDistance distanceBetweenPoints = [lastLocationSeen distanceFromLocation:loc];
            if(distanceBetweenPoints < self.discardPointsWithinDistanceCurrentValue) {
                // NSLog(@"Discarding location because this point is too close to the previous: %f", distanceBetweenPoints);
                continue;
            }
        }

        if(self.discardPointsWithinSecondsCurrentValue > 1) {
            int timeInterval = (int)[loc.timestamp timeIntervalSinceDate:lastLocationSeen.timestamp];
            if(timeInterval < self.discardPointsWithinSecondsCurrentValue) {
                continue;
            }
        }
        
        NSString *timestamp = [GLManager iso8601DateStringFromDate:loc.timestamp];
        NSDictionary *update;
        if(self.loggingModeCurrentValue == kGLLoggingModeOwntracks) {
            update = [self owntracksDictionaryFromLocation:loc];
        } else {
            update = [self currentDictionaryFromLocation:loc];
            NSMutableDictionary *properties = [update objectForKey:@"properties"];
            if(self.includeTrackingStats) {
                [properties setValue:[NSNumber numberWithBool:self.locationManager.pausesLocationUpdatesAutomatically] forKey:@"pauses"];
                [properties setValue:activityType forKey:@"activity"];
                [properties setValue:[NSNumber numberWithDouble:self.locationManager.desiredAccuracy] forKey:@"desired_accuracy"];
                [properties setValue:[NSNumber numberWithInt:self.trackingMode] forKey:@"tracking_mode"];
                [properties setValue:[NSNumber numberWithLong:locations.count] forKey:@"locations_in_payload"];
            }
        }

        // Queue the point in the database
        [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
            if(self.loggingModeCurrentValue == kGLLoggingModeOnlyLatest || self.loggingModeCurrentValue == kGLLoggingModeOwntracks) {
                // Delete everything in the DB so that this new point is the only one in the queue after it's added below
                [accessor deleteAllData];
            }
            [accessor setDictionary:update forKey:timestamp];
        }];
        didAddData = YES;

        self.lastLocation = loc;
        self.lastLocationDictionary = [self currentDictionaryFromLocation:self.lastLocation];

    }

    if(didAddData) {
        [[NSNotificationCenter defaultCenter] postNotificationName:GLNewDataNotification object:self];
    }

    [self sendQueueIfTimeElapsed];
    
    [self scheduleLocalNotification];
}

- (void)addMetadataToUpdate:(NSDictionary *) update {
    NSMutableDictionary *properties = [update objectForKey:@"properties"];
    if(_deviceId && _deviceId.length > 0) {
        [properties setValue:_deviceId forKey:@"device_id"];
    }
    [properties setValue:[GLManager currentWifiHotSpotName] forKey:@"wifi"];
    [properties setValue:[self currentBatteryState] forKey:@"battery_state"];
    [properties setValue:[self currentBatteryLevel] forKey:@"battery_level"];
    if([[NSUserDefaults standardUserDefaults] boolForKey:GLIncludeUniqueIdDefaultsName]) {
        NSString *uniqueId = [UIDevice currentDevice].identifierForVendor.UUIDString;
        [properties setValue:uniqueId forKey:@"unique_id"];
    }
}

- (NSDictionary *)currentDictionaryFromLocation:(CLLocation *)loc {
    NSString *timestamp = [GLManager iso8601DateStringFromDate:loc.timestamp];
    NSDictionary *update = @{
             @"type": @"Feature",
             @"geometry": @{
                     @"type": @"Point",
                     @"coordinates": @[
                             [NSNumber numberWithDouble:((int)(loc.coordinate.longitude * 10000000)) / 10000000.0],
                             [NSNumber numberWithDouble:((int)(loc.coordinate.latitude * 10000000)) / 10000000.0]
                             ]
                     },
             @"properties": [NSMutableDictionary dictionaryWithDictionary:@{
                     @"timestamp": timestamp,
                     @"altitude": [NSNumber numberWithInt:(int)round(loc.altitude)],
                     @"speed": [NSNumber numberWithDouble:((int)(loc.speed * 100)) / 100.0],
                     @"course": [NSNumber numberWithInt:(int)round(loc.course)],
                     @"horizontal_accuracy": [NSNumber numberWithInt:(int)round(loc.horizontalAccuracy)],
                     @"vertical_accuracy": [NSNumber numberWithInt:(int)round(loc.verticalAccuracy)],
                     @"speed_accuracy": [NSNumber numberWithDouble:((int)(loc.speedAccuracy * 100)) / 100.0],
                     @"course_accuracy": [NSNumber numberWithDouble:((int)(loc.courseAccuracy * 100)) / 100.0],
                     @"motion": [self motionArrayFromLastMotion],
                     }]
             };
    [self addMetadataToUpdate:update];
    return update;
}

- (NSDictionary *)owntracksDictionaryFromLocation:(CLLocation *)loc {
    NSMutableDictionary *update = [NSMutableDictionary dictionaryWithDictionary:@{
        @"_type": @"location",
        @"lat": [NSNumber numberWithDouble:((int)(loc.coordinate.latitude * 10000000)) / 10000000.0],
        @"lon": [NSNumber numberWithDouble:((int)(loc.coordinate.longitude * 10000000)) / 10000000.0],
        @"tst": [NSNumber numberWithInt:(int)loc.timestamp.timeIntervalSinceReferenceDate],
        @"acc": [NSNumber numberWithInt:(int)round(loc.horizontalAccuracy)],
        @"batt": [NSNumber numberWithInt:[[self currentBatteryLevel] doubleValue] * 100],
    }];
    if(_deviceId && _deviceId.length > 0) {
        NSString *topic = [NSString stringWithFormat:@"owntracks/%@", _deviceId];
        [update setValue:topic forKey:@"topic"];
    }
    return update;
}

- (NSArray *)motionArrayFromLastMotion {
    NSMutableArray *motion = [[NSMutableArray alloc] init];
    CMMotionActivity *motionActivity = [GLManager sharedManager].lastMotion;
    if(motionActivity.walking)
        [motion addObject:@"walking"];
    if(motionActivity.running)
        [motion addObject:@"running"];
    if(motionActivity.cycling)
        [motion addObject:@"cycling"];
    if(motionActivity.automotive)
        [motion addObject:@"driving"];
    if(motionActivity.stationary)
        [motion addObject:@"stationary"];
    return [NSArray arrayWithArray:motion];
}

- (void)locationManagerDidPauseLocationUpdates:(CLLocationManager *)manager {
    [self logAction:@"paused_location_updates"];
    
    [self notify:@"Location updates paused" withTitle:@"Paused"];
    
    // Create an exit geofence to help it resume automatically
    if(self.resumesAfterDistance > 0) {
        CLCircularRegion *region = [[CLCircularRegion alloc] initWithCenter:self.lastLocation.coordinate radius:self.resumesAfterDistance identifier:@"resume-from-pause"];
        region.notifyOnEntry = NO;
        region.notifyOnExit = YES;
        [self.locationManager startMonitoringForRegion:region];
    }
    
    // Send the queue now to flush all remaining points
    [self sendQueueIfNotInProgress];
}

-(void)locationManager:(CLLocationManager *)manager didExitRegion:(CLRegion *)region {
    NSLog(@"Did exit region");
    [self logAction:@"exited_pause_region"];
    [self notify:@"Starting updates from exiting the geofence" withTitle:@"Resumed"];
    [self.locationManager stopMonitoringForRegion:region];
    [self enableTracking];
}

- (void)locationManagerDidResumeLocationUpdates:(CLLocationManager *)manager {
    [self logAction:@"resumed_location_updates"];
    [self notify:@"Location updates resumed" withTitle:@"Resumed"];
}

#pragma mark - AppDelegate Methods

- (void)applicationDidEnterBackground {
    // [self logAction:@"did_enter_background"];
}

- (void)applicationWillTerminate {
    [self logAction:@"will_terminate"];
}

- (void)applicationWillResignActive {
    // [self logAction:@"will_resign_active"];
}

#pragma mark - Notifications

- (BOOL)notificationsEnabled {
    if([self defaultsKeyExists:GLNotificationsEnabledDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] boolForKey:GLNotificationsEnabledDefaultsName];
    } else {
        return NO;
    }
}
- (void)setNotificationsEnabled:(BOOL)enabled {
    if(enabled) {
        [self requestNotificationPermission];
    } else {
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:GLNotificationsEnabledDefaultsName];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:GLNotificationPermissionRequestedDefaultsName];
    }
}

- (void)initializeNotifications {
    UNUserNotificationCenter *notificationCenter = [UNUserNotificationCenter currentNotificationCenter];
    notificationCenter.delegate = self;
    
    // If notifications were successfully requested previously, initialize again for this app launch
    if([[NSUserDefaults standardUserDefaults] boolForKey:GLNotificationPermissionRequestedDefaultsName]) {
        [self requestNotificationPermission];
    }
}

- (void)requestNotificationPermission {
    UNUserNotificationCenter *notificationCenter = [UNUserNotificationCenter currentNotificationCenter];

    UNAuthorizationOptions options = UNAuthorizationOptionAlert + UNAuthorizationOptionSound;
    [notificationCenter requestAuthorizationWithOptions:options
                                      completionHandler:^(BOOL granted, NSError * _Nullable error) {
                                          // If the user denies permission, set requested=NO so that if they ever enable it in settings again the permission will be requested again
                                          [[NSUserDefaults standardUserDefaults] setBool:granted forKey:GLNotificationPermissionRequestedDefaultsName];
                                          [[NSUserDefaults standardUserDefaults] setBool:granted forKey:GLNotificationsEnabledDefaultsName];
                                          if(!granted) {
                                              NSLog(@"User did not allow notifications");
                                          }
                                      }];
}

- (void)notify:(NSString *)message withTitle:(NSString *)title
{
    if([self notificationsEnabled]) {
        UNUserNotificationCenter *notificationCenter = [UNUserNotificationCenter currentNotificationCenter];
        
        UNMutableNotificationContent *content = [UNMutableNotificationContent new];
        content.title = title;
        content.body = message;
        content.sound = [UNNotificationSound defaultSound];
        
        /* UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:1 repeats:NO]; */
        
        NSString *identifier = @"GLLocalNotification";
        UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier
                                                                              content:content
                                                                              trigger:nil];
        
        [notificationCenter addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
            if (error != nil) {
                NSLog(@"Something went wrong: %@",error);
            } else {
                NSLog(@"Notification sent");
            }
        }];
    }
}

/* Force notifications to display as normal when the app is active */
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler {
    
    completionHandler(UNNotificationPresentationOptionList | UNNotificationPresentationOptionBanner);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(nonnull UNNotificationResponse *)response withCompletionHandler:(nonnull void (^)(void))completionHandler
{
    completionHandler();
}


#pragma mark - Wifi Positioning

/*
 Allow the user to configure wifi names mapping to locations. If the phone is connected to
 one of the known wifi names, use the configured location instead of the phone's reported location.
 This should help avoid GPS drift around common locations like "home" and "work", and can
 also be used to pause location updates when the user gets home.
*/

- (CLLocation *)currentLocationFromWifiName:(NSString *)wifi {
    if(wifi == nil) {
        return nil;
    }
    
    if(self.wifiZoneName) {
    
        if([self.wifiZoneName isEqualToString:wifi]) {
            double latitude = [self.wifiZoneLatitude floatValue];
            double longitude = [self.wifiZoneLongitude floatValue];
            CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(latitude, longitude);
            NSDate *timestamp = NSDate.date;
            
            CLLocation *loc = [[CLLocation alloc] initWithCoordinate:coord
                                                            altitude:-1
                                                  horizontalAccuracy:1
                                                    verticalAccuracy:0
                                                              course:0
                                                               speed:0
                                                           timestamp:timestamp];
            return loc;
        }
    }
    
    return nil;
}

- (void)saveNewWifiZone:(NSString *)name withLatitude:(NSString *)latitude andLongitude:(NSString *)longitude {
    
    [[NSUserDefaults standardUserDefaults] setObject:name forKey:@"WifiZoneName"];
    [[NSUserDefaults standardUserDefaults] setObject:latitude forKey:@"WifiZoneLatitude"];
    [[NSUserDefaults standardUserDefaults] setObject:longitude forKey:@"WifiZoneLongitude"];
}
- (NSString *)wifiZoneName {
    return [[NSUserDefaults standardUserDefaults] objectForKey:@"WifiZoneName"];
}
- (NSString *)wifiZoneLatitude {
    return [[NSUserDefaults standardUserDefaults] objectForKey:@"WifiZoneLatitude"];
}
- (NSString *)wifiZoneLongitude {
    return [[NSUserDefaults standardUserDefaults] objectForKey:@"WifiZoneLongitude"];
}


#pragma mark -

- (BOOL)defaultsKeyExists:(NSString *)key {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [[[defaults dictionaryRepresentation] allKeys] containsObject:key];
}

+ (NSString *)currentWifiHotSpotName {
    NSString *wifiName = @"";
    NSArray *ifs = (__bridge_transfer id)CNCopySupportedInterfaces();
    for (NSString *ifnam in ifs) {
        NSDictionary *info = (__bridge_transfer id)CNCopyCurrentNetworkInfo((__bridge CFStringRef)ifnam);
        if (info[@"SSID"]) {
            wifiName = info[@"SSID"];
        }
    }
    return wifiName;
}

#pragma mark - LOLDB

+ (NSString *)cacheDatabasePath
{
    NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    return [caches stringByAppendingPathComponent:@"GLLoggerCache.sqlite"];
}

+ (id)objectFromJSONData:(NSData *)data error:(NSError **)error;
{
    return [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:error];
}

+ (NSData *)dataWithJSONObject:(id)object error:(NSError **)error;
{
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:error];
}

+ (NSString *)iso8601DateStringFromDate:(NSDate *)date {
    struct tm *timeinfo;
    char buffer[80];
    
    time_t rawtime = (time_t)[date timeIntervalSince1970];
    timeinfo = gmtime(&rawtime);
    
    strftime(buffer, 80, "%Y-%m-%dT%H:%M:%SZ", timeinfo);
    
    return [NSString stringWithCString:buffer encoding:NSUTF8StringEncoding];
}

@end
