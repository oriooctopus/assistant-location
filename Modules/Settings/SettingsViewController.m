//
//  SecondViewController.m
//  App
//
//  Created by Aaron Parecki on 9/17/15.
//  Copyright © 2015 Esri. All rights reserved.
//  Copyright © 2017 Aaron Parecki. All rights reserved.
//

#import "SettingsViewController.h"
#import "GLManager.h"
#import "GLTheme.h"
#import "GLLog.h"
#import "BakedConfig.h"

#import  <Intents/Intents.h>
#import <SafariServices/SafariServices.h>

// The palette picker talks to the same events server tab uses for its own
// web UI (Modules/Events/EventsViewController.m); this module owns no server
// of its own, it just reads/writes the shared ~/.config/assistant/ui-prefs.json
// that server exposes over HTTP.
static NSInteger const kThemeServerPort = 8304;

@interface SettingsViewController ()

/* The simplified settings screen, built in code on top of the storyboard's
   stack view. See buildSimplifiedSettings. */
@property (strong, nonatomic) UILabel *locationPermissionLabel;

/* Theme (palette) picker — see buildThemeSection. */
@property (strong, nonatomic) UIStackView *themeOptionsContainer;
@property (strong, nonatomic) NSArray<NSDictionary *> *availableThemes;
@property (copy, nonatomic, nullable) NSString *currentThemeId; // nil = Auto

@end

@implementation SettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self buildSimplifiedSettings];
}

#pragma mark - Simplified settings

/* Assistant fork: the app is a single-purpose background tracker configured by
   the overland://setup link and by settings pushed back in upload responses,
   so every inherited knob (tracking mode, accuracy, activity type, pausing,
   logging mode, batch size, visit tracking, background indicator, geofence
   resume, wifi zones, tip jar) is hidden. The endpoint and token are gone from
   this screen too: both are compiled in at build time (BakedConfig.h) and
   re-forced on every launch, so there is nothing here to set and showing them
   would only be clutter. The once-per-build launch alert in SceneDelegate
   reports the endpoint, the live Authorization header and the permission
   state when a build actually needs diagnosing.

   All that is left is the location-permission status, the one thing that
   silently breaks background tracking and that only the user can fix.

   The controls are hidden rather than deleted from the storyboard: the code
   that reads and writes their underlying NSUserDefaults values is untouched,
   so a server-pushed setting still applies exactly as before. */
- (void)buildSimplifiedSettings {
    for(UIView *row in self.settingsStackView.arrangedSubviews) {
        row.hidden = YES;
    }

    // "Configure Wifi Zone" is the one inherited row the user still needs —
    // it's how home-drift gets fixed — so un-hide it specifically rather
    // than leaving it buried with every other inherited knob.
    self.configureWifiZoneButton.hidden = NO;

    [self.settingsStackView insertArrangedSubview:[self buildAppearanceSection] atIndex:0];
    [self.settingsStackView insertArrangedSubview:[self buildThemeSection] atIndex:1];

    UILabel *note = [self captionLabelWithText:@"Configured at build time."];
    note.textColor = [UIColor secondaryLabelColor];
    [self.settingsStackView addArrangedSubview:note];

    self.locationPermissionLabel = [self captionLabelWithText:@""];
    self.locationPermissionLabel.numberOfLines = 0;
    [self.settingsStackView addArrangedSubview:self.locationPermissionLabel];
}

#pragma mark - Appearance

/// App-level System/Light/Dark control, above every location row, bound to
/// GLTheme's persisted mode. Changing it applies immediately across the app
/// (native tabs via GLTheme.setCurrentMode's override, web tabs via
/// GLThemeDidChangeNotification, which GLWebModuleViewController observes).
- (UIView *)buildAppearanceSection {
    UILabel *label = [self captionLabelWithText:@"Appearance"];

    UISegmentedControl *control =
        [[UISegmentedControl alloc] initWithItems:@[@"System", @"Light", @"Dark"]];
    control.selectedSegmentIndex = [GLTheme currentMode];
    [control addTarget:self
                action:@selector(appearanceModeWasChanged:)
      forControlEvents:UIControlEventValueChanged];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[label, control]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = [GLTheme spacingXS];
    return stack;
}

- (void)appearanceModeWasChanged:(UISegmentedControl *)sender {
    [GLTheme setCurrentMode:(GLThemeMode)sender.selectedSegmentIndex];
}

#pragma mark - Theme (palette)

/// The palette picker moved here from the events web app's ⋮ menu — it's an
/// app-wide preference (shared by the events/todos/journal web tabs, all
/// stored in one ~/.config/assistant/ui-prefs.json on the box), so one place
/// to set it belongs in Settings rather than duplicated per web tab.
///
/// This is separate from buildAppearanceSection above: that's the native
/// System/Light/Dark UIKit override, this is which server-side colour
/// palette the web tabs render (light/dark/void/dusk/...). The two are
/// independent knobs that happen to both live under "Appearance".
- (UIView *)buildThemeSection {
    UILabel *label = [self captionLabelWithText:@"Theme"];

    self.themeOptionsContainer = [[UIStackView alloc] init];
    self.themeOptionsContainer.axis = UILayoutConstraintAxisVertical;
    self.themeOptionsContainer.spacing = [GLTheme spacingXXS];
    [self showThemeStatus:@"Loading…"];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[label, self.themeOptionsContainer]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = [GLTheme spacingXS];

    [self loadThemeSection];

    return stack;
}

/// Builds `http://GL_BAKED_HOST:8304<path>` directly, the same way
/// EventsViewController does — never GLEndpointURL, which raises when the
/// host is unbaked (true for every sim-test run: the workflow never bakes
/// GL_BAKED_HOST). An unbaked/unreachable host must fail through
/// NSURLSession's ordinary error path so the section degrades to
/// "unavailable" instead of crashing.
- (NSURL *)themeServerURLWithPath:(NSString *)path {
    NSString *urlString = [NSString stringWithFormat:@"http://%@:%ld%@", GL_BAKED_HOST, (long)kThemeServerPort, path];
    return [NSURL URLWithString:urlString];
}

- (void)loadThemeSection {
    NSURL *url = [self themeServerURLWithPath:@"/themes.json"];
    if (!url) { [self showThemeUnavailable]; return; }

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithURL:url
      completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleThemesResponse:response data:data error:error];
        });
    }];
    [task resume];
}

- (void)handleThemesResponse:(NSURLResponse *)response data:(NSData *)data error:(NSError *)error {
    NSArray *themes = [self JSONArrayFromResponse:response data:data error:error];
    if (!themes) {
        [self showThemeUnavailable];
        return;
    }
    self.availableThemes = themes;
    [self loadCurrentTheme];
}

- (void)loadCurrentTheme {
    NSURL *url = [self themeServerURLWithPath:@"/api/theme"];
    if (!url) { [self showThemeUnavailable]; return; }

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithURL:url
      completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleCurrentThemeResponse:response data:data error:error];
        });
    }];
    [task resume];
}

- (void)handleCurrentThemeResponse:(NSURLResponse *)response data:(NSData *)data error:(NSError *)error {
    NSDictionary *parsed = [self JSONObjectFromResponse:response data:data error:error];
    if (!parsed) {
        [self showThemeUnavailable];
        return;
    }
    id themeValue = parsed[@"theme"];
    self.currentThemeId = [themeValue isKindOfClass:[NSString class]] ? themeValue : nil;
    [self renderThemeOptions];
}

/// Shared success/parse gate for both endpoints: any network error, non-2xx
/// status, or malformed JSON is treated identically — the section can't tell
/// (and doesn't need to tell) "box unreachable" apart from "box replied with
/// garbage", both just mean "unavailable".
- (nullable id)JSONFromResponse:(NSURLResponse *)response data:(NSData *)data error:(NSError *)error expectedClass:(Class)expectedClass {
    if (error || data.length == 0) return nil;
    NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
    if (status < 200 || status > 299) return nil;
    NSError *jsonError = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (jsonError || ![parsed isKindOfClass:expectedClass]) return nil;
    return parsed;
}

- (nullable NSArray *)JSONArrayFromResponse:(NSURLResponse *)response data:(NSData *)data error:(NSError *)error {
    return [self JSONFromResponse:response data:data error:error expectedClass:[NSArray class]];
}

- (nullable NSDictionary *)JSONObjectFromResponse:(NSURLResponse *)response data:(NSData *)data error:(NSError *)error {
    return [self JSONFromResponse:response data:data error:error expectedClass:[NSDictionary class]];
}

- (void)showThemeUnavailable {
    [self showThemeStatus:@"Theme picker unavailable — can't reach the server."];
}

- (void)showThemeStatus:(NSString *)text {
    for (UIView *row in self.themeOptionsContainer.arrangedSubviews) {
        [row removeFromSuperview];
    }
    UILabel *status = [self captionLabelWithText:text];
    status.textColor = [UIColor secondaryLabelColor];
    status.numberOfLines = 0;
    [self.themeOptionsContainer addArrangedSubview:status];
}

- (void)renderThemeOptions {
    for (UIView *row in self.themeOptionsContainer.arrangedSubviews) {
        [row removeFromSuperview];
    }

    [self.themeOptionsContainer addArrangedSubview:
        [self themeRowWithId:nil label:@"Auto" selected:(self.currentThemeId == nil)]];

    for (NSDictionary *theme in self.availableThemes) {
        NSString *themeId = theme[@"id"];
        NSString *themeLabel = theme[@"label"];
        if (![themeId isKindOfClass:[NSString class]] || ![themeLabel isKindOfClass:[NSString class]]) {
            continue;
        }
        BOOL selected = [themeId isEqualToString:self.currentThemeId];
        [self.themeOptionsContainer addArrangedSubview:
            [self themeRowWithId:themeId label:themeLabel selected:selected]];
    }
}

- (UIButton *)themeRowWithId:(nullable NSString *)themeId label:(NSString *)label selected:(BOOL)selected {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    NSString *title = selected ? [NSString stringWithFormat:@"%@  ✓", label] : label;
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:16];
    [button setTitleColor:[GLTheme textPrimaryColor] forState:UIControlStateNormal];
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [button addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        [self themeWasSelected:themeId];
    }] forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)themeWasSelected:(nullable NSString *)themeId {
    if ([themeId isEqualToString:self.currentThemeId] || (!themeId && !self.currentThemeId)) {
        return;
    }
    // Optimistic: update the checkmark immediately, don't wait on the PUT.
    self.currentThemeId = themeId;
    [self renderThemeOptions];

    NSURL *url = [self themeServerURLWithPath:@"/api/theme"];
    if (!url) return;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"PUT";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{ @"theme": themeId ?: [NSNull null] }
                                                        options:0
                                                          error:nil];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            GLLog(@"PUT /api/theme failed: %@", error.localizedDescription);
            return;
        }
        // Re-fetch on the main queue only once the write is confirmed
        // committed server-side -- re-fetching eagerly (before this
        // completion) could race the PUT and read back the OLD theme id.
        // Without this, picking a theme here only re-themed the web tabs
        // (which independently re-fetch /api/theme on their own); the
        // native tab bar/nav bars would keep showing the previous palette
        // until the app was force-quit and relaunched.
        dispatch_async(dispatch_get_main_queue(), ^{
            [GLTheme refreshPaletteFromServer];
        });
    }];
    [task resume];
}

- (UILabel *)captionLabelWithText:(NSString *)text {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = [UIFont systemFontOfSize:14];
    label.textColor = [UIColor labelColor];
    return label;
}

- (void)updateSimplifiedSettings {
    // authorizationStatusChanged un-hides this inherited row whenever the
    // permission isn't Always; keep it hidden.
    self.locationAuthorizationStatusSection.hidden = YES;

    CLAuthorizationStatus status = [GLManager sharedManager].locationManager.authorizationStatus;
    switch(status) {
        case kCLAuthorizationStatusAuthorizedAlways:
            self.locationPermissionLabel.text = @"Location: Always ✓";
            self.locationPermissionLabel.textColor = [UIColor labelColor];
            break;
        case kCLAuthorizationStatusAuthorizedWhenInUse:
            self.locationPermissionLabel.text = @"Location: While Using — background tracking needs Always";
            self.locationPermissionLabel.textColor = [UIColor systemRedColor];
            break;
        case kCLAuthorizationStatusDenied:
            self.locationPermissionLabel.text = @"Location: Denied — background tracking needs Always";
            self.locationPermissionLabel.textColor = [UIColor systemRedColor];
            break;
        case kCLAuthorizationStatusRestricted:
            self.locationPermissionLabel.text = @"Location: Restricted — background tracking needs Always";
            self.locationPermissionLabel.textColor = [UIColor systemRedColor];
            break;
        case kCLAuthorizationStatusNotDetermined:
            self.locationPermissionLabel.text = @"Location: Not Determined — background tracking needs Always";
            self.locationPermissionLabel.textColor = [UIColor systemRedColor];
            break;
    }
}

- (void)viewWillAppear:(BOOL)animated {
    
    [self lockAllControls];
    self.settingsLockSlider.value = 0;

    [self updateVisibleSettings];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(authorizationStatusChanged)
                                                 name:GLAuthorizationStatusChangedNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateVisibleSettings)
                                                 name:GLSettingsChangedNotification
                                               object:nil];

}

- (void)viewDidDisappear:(BOOL)animated {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)settingsLockSliderWasChanged:(UISlider *)sender {
    if(sender.value > 95) {
        [self unlockAllControls];
    } else {
        [self lockAllControls];
    }
}

- (void)lockAllControls {
    self.apiEndpointField.enabled = NO;
    self.trackingEnabledToggle.enabled = NO;
    self.trackingEnabledToggle.enabled = NO;
    self.continuousTrackingMode.enabled = NO;
    self.visitTrackingControl.enabled = NO;
    self.desiredAccuracy.enabled = NO;
    self.activityType.enabled = NO;
    self.showBackgroundLocationIndicator.enabled = NO;
    self.pausesAutomatically.enabled = NO;
    self.loggingMode.enabled = NO;
    self.pointsPerBatchControl.enabled = NO;
    self.resumesWithGeofence.enabled = NO;
    self.discardPointsWithinDistance.enabled = NO;
    self.discardPointsWithinSeconds.enabled = NO;
    self.enableNotifications.enabled = NO;
    self.locationAuthorizationStatus.enabled = NO;
    self.locationAuthorizationStatusWarning.enabled = NO;
    self.requestLocationPermissionsButton.enabled = NO;
}

- (void)unlockAllControls {
    self.apiEndpointField.enabled = YES;
    self.trackingEnabledToggle.enabled = YES;
    self.trackingEnabledToggle.enabled = YES;
    self.continuousTrackingMode.enabled = YES;
    self.visitTrackingControl.enabled = YES;
    self.desiredAccuracy.enabled = YES;
    self.activityType.enabled = YES;
    self.showBackgroundLocationIndicator.enabled = YES;
    self.pausesAutomatically.enabled = YES;
    self.loggingMode.enabled = YES;
    self.pointsPerBatchControl.enabled = YES;
    self.resumesWithGeofence.enabled = YES;
    self.discardPointsWithinDistance.enabled = YES;
    self.discardPointsWithinSeconds.enabled = YES;
    self.enableNotifications.enabled = YES;
    self.locationAuthorizationStatus.enabled = YES;
    self.locationAuthorizationStatusWarning.enabled = YES;
    self.requestLocationPermissionsButton.enabled = YES;
}

- (void)authorizationStatusChanged {
    self.locationAuthorizationStatus.text = [GLManager sharedManager].authorizationStatusAsString;
    if (@available(iOS 14.0, *)) {
        if([GLManager sharedManager].locationManager.authorizationStatus != kCLAuthorizationStatusAuthorizedAlways) {
            self.locationAuthorizationStatusWarning.hidden = false;
            self.requestLocationPermissionsButton.hidden = false;
            self.locationAuthorizationStatusSection.hidden = false;
        } else {
            self.locationAuthorizationStatusWarning.hidden = true;
            self.requestLocationPermissionsButton.hidden = true;
            self.locationAuthorizationStatusSection.hidden = true;
        }
    }
    // Runs last: the block above is the only thing that un-hides an inherited
    // row, and the simplified screen shows permission status as a plain label.
    [self updateSimplifiedSettings];
}

- (void)updateVisibleSettings {
    if([GLManager sharedManager].apiEndpointURL != nil) {
        self.apiEndpointField.text = [GLManager sharedManager].apiEndpointURL;
    } else {
        self.apiEndpointField.text = @"tap to set endpoint";
    }

    self.trackingEnabledToggle.selectedSegmentIndex = ([GLManager sharedManager].trackingEnabled ? 1 : 0);
    self.pausesAutomatically.selectedSegmentIndex = ([GLManager sharedManager].pausesAutomatically ? 1 : 0);
    self.showBackgroundLocationIndicator.selectedSegmentIndex = ([GLManager sharedManager].showBackgroundLocationIndicator ? 1 : 0);
    self.enableNotifications.on = [GLManager sharedManager].notificationsEnabled;
    
    [self authorizationStatusChanged];
    
    self.activityType.selectedSegmentIndex = [GLManager sharedManager].activityType - 1;

    GLTrackingMode trackingMode = [GLManager sharedManager].trackingMode;
    switch(trackingMode) {
        case kGLTrackingModeOff:
            self.continuousTrackingMode.selectedSegmentIndex = 0;
            break;
        case kGLTrackingModeStandard:
            self.continuousTrackingMode.selectedSegmentIndex = 1;
            break;
        case kGLTrackingModeSignificant:
            self.continuousTrackingMode.selectedSegmentIndex = 2;
            break;
        case kGLTrackingModeStandardAndSignificant:
            self.continuousTrackingMode.selectedSegmentIndex = 3;
            break;
    }
    
    self.visitTrackingControl.selectedSegmentIndex = ([GLManager sharedManager].visitTrackingEnabled ? 1 : 0);
    
    GLLoggingMode loggingMode = [GLManager sharedManager].loggingMode;
    switch(loggingMode) {
        case kGLLoggingModeAllData:
            self.loggingMode.selectedSegmentIndex = 0;
            break;
        case kGLLoggingModeOnlyLatest:
            self.loggingMode.selectedSegmentIndex = 1;
            break;
        case kGLLoggingModeOwntracks:
            self.loggingMode.selectedSegmentIndex = 2;
            break;
    }
    
    CLLocationDistance gDist = [GLManager sharedManager].resumesAfterDistance;
    int gIdx = 0;
    switch((int)gDist) {
        case -1:
            gIdx = 0; break;
        case 100:
            gIdx = 1; break;
        case 200:
            gIdx = 2; break;
        case 500:
            gIdx = 3; break;
        case 1000:
            gIdx = 4; break;
        case 2000:
            gIdx = 5; break;
    }
    self.resumesWithGeofence.selectedSegmentIndex = gIdx;
    
    CLLocationDistance discardDistance = [GLManager sharedManager].discardPointsWithinDistance;
    int dIdx = 0;
    switch((int)discardDistance) {
        case -1:
            dIdx = 0; break;
        case 1:
            dIdx = 1; break;
        case 10:
            dIdx = 2; break;
        case 50:
            dIdx = 3; break;
        case 100:
            dIdx = 4; break;
        case 500:
            dIdx = 5; break;
    }
    self.discardPointsWithinDistance.selectedSegmentIndex = dIdx;
    
    int discardSeconds = [GLManager sharedManager].discardPointsWithinSeconds;
    switch(discardSeconds) {
        case 1:
            self.discardPointsWithinSeconds.selectedSegmentIndex = 0; break;
        case 5:
            self.discardPointsWithinSeconds.selectedSegmentIndex = 1; break;
        case 10:
            self.discardPointsWithinSeconds.selectedSegmentIndex = 2; break;
        case 30:
            self.discardPointsWithinSeconds.selectedSegmentIndex = 3; break;
        case 60:
            self.discardPointsWithinSeconds.selectedSegmentIndex = 4; break;
        case 120:
            self.discardPointsWithinSeconds.selectedSegmentIndex = 5; break;
    }
    
    CLLocationAccuracy d = [GLManager sharedManager].desiredAccuracy;
    if(d == kCLLocationAccuracyBestForNavigation) {
        self.desiredAccuracy.selectedSegmentIndex = 0;
    } else if(d == kCLLocationAccuracyBest) {
        self.desiredAccuracy.selectedSegmentIndex = 1;
    } else if(d == kCLLocationAccuracyNearestTenMeters) {
        self.desiredAccuracy.selectedSegmentIndex = 2;
    } else if(d == kCLLocationAccuracyHundredMeters) {
        self.desiredAccuracy.selectedSegmentIndex = 3;
    } else if(d == kCLLocationAccuracyKilometer) {
        self.desiredAccuracy.selectedSegmentIndex = 4;
    } else if(d == kCLLocationAccuracyThreeKilometers) {
        self.desiredAccuracy.selectedSegmentIndex = 5;
    }
    
    int pointsPerBatch = [GLManager sharedManager].pointsPerBatch;
    if(pointsPerBatch == 50) {
        self.pointsPerBatchControl.selectedSegmentIndex = 0;
    } else if(pointsPerBatch == 100) {
        self.pointsPerBatchControl.selectedSegmentIndex = 1;
    } else if(pointsPerBatch == 200) {
        self.pointsPerBatchControl.selectedSegmentIndex = 2;
    } else if(pointsPerBatch == 500) {
        self.pointsPerBatchControl.selectedSegmentIndex = 3;
    } else if(pointsPerBatch == 1000) {
        self.pointsPerBatchControl.selectedSegmentIndex = 4;
    }
}

- (IBAction)toggleLogging:(UISegmentedControl *)sender {
    NSLog(@"Logging: %@", [sender titleForSegmentAtIndex:sender.selectedSegmentIndex]);
    
    if(sender.selectedSegmentIndex == 1) {
        [[GLManager sharedManager] startAllUpdates];
    } else {
        [[GLManager sharedManager] stopAllUpdates];
    }
}

-(IBAction)loggingModeWasChanged:(UISegmentedControl *)sender {
    if(sender.selectedSegmentIndex == 0) {
        [GLManager sharedManager].loggingMode = kGLLoggingModeAllData;
    } else {
        
        [[GLManager sharedManager] numberOfLocationsInQueue:^(long num) {
            if(num == 0) {
                if(sender.selectedSegmentIndex == 1) {
                    [GLManager sharedManager].loggingMode = kGLLoggingModeOnlyLatest;
                } else {
                    [GLManager sharedManager].loggingMode = kGLLoggingModeOwntracks;
                }
            } else {
                
                NSString *string = [NSString stringWithFormat:@"This will delete the %d locations in the queue that are not yet sent", (int)num];
                UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Are you sure?"
                                                                               message:string
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleDefault
                                                                     handler:^(UIAlertAction * action) {
                    sender.selectedSegmentIndex = 0;
                                                                     }];
                UIAlertAction* confirmAction = [UIAlertAction actionWithTitle:@"Yes" style:UIAlertActionStyleDefault
                                                                     handler:^(UIAlertAction * action) {
                    if(sender.selectedSegmentIndex == 1) {
                        [GLManager sharedManager].loggingMode = kGLLoggingModeOnlyLatest;
                    } else {
                        [GLManager sharedManager].loggingMode = kGLLoggingModeOwntracks;
                    }

                }];
                [alert addAction:confirmAction];
                [alert addAction:cancelAction];
                [self presentViewController:alert animated:YES completion:nil];

            }
        }];
        
    }
}

- (IBAction)requestLocationPermissionsWasPressed:(UIButton *)sender {
    [[GLManager sharedManager] requestAuthorizationPermission];
}

- (IBAction)pausesAutomaticallyWasChanged:(UISegmentedControl *)sender {
    [GLManager sharedManager].pausesAutomatically = sender.selectedSegmentIndex == 1;
    if(sender.selectedSegmentIndex == 0) {
        self.resumesWithGeofence.selectedSegmentIndex = 0;
        [GLManager sharedManager].resumesAfterDistance = -1;
    }
}

- (IBAction)resumeWithGeofenceWasChanged:(UISegmentedControl *)sender {
    CLLocationDistance distance = -1;
    switch(sender.selectedSegmentIndex) {
        case 0:
            distance = -1; break;
        case 1:
            distance = 100; break;
        case 2:
            distance = 200; break;
        case 3:
            distance = 500; break;
        case 4:
            distance = 1000; break;
        case 5:
            distance = 2000; break;
    }
    if(distance > 0) {
        self.pausesAutomatically.selectedSegmentIndex = 1;
        [GLManager sharedManager].pausesAutomatically = YES;
    }
    [GLManager sharedManager].resumesAfterDistance = distance;
}

- (IBAction)continuousTrackingModeWasChanged:(UISegmentedControl *)sender {
    GLTrackingMode m = kGLTrackingModeStandard;
    switch(sender.selectedSegmentIndex) {
        case 0:
            m = kGLTrackingModeOff; break;
        case 1:
            m = kGLTrackingModeStandard; break;
        case 2:
            m = kGLTrackingModeSignificant; break;
        case 3:
            m = kGLTrackingModeStandardAndSignificant; break;
    }
    [GLManager sharedManager].trackingMode = m;
}

- (IBAction)visitTrackingWasChanged:(UISegmentedControl *)sender {
    BOOL enabled = NO;
    switch(sender.selectedSegmentIndex) {
        case 0:
            enabled = NO; break;
        case 1:
            enabled = YES; break;
    }
    [GLManager sharedManager].visitTrackingEnabled = enabled;
}

- (IBAction)showBackgroundLocationIndicatorWasChanged:(UISegmentedControl *)sender {
    BOOL m = NO;
    switch(sender.selectedSegmentIndex) {
        case 0:
            m = NO; break;
        case 1:
            m = YES; break;
    }
    [GLManager sharedManager].showBackgroundLocationIndicator = m;
}

- (IBAction)discardPointsWithinDistanceWasChanged:(UISegmentedControl *)sender {
    CLLocationDistance distance = -1;
    switch(sender.selectedSegmentIndex) {
        case 0:
            distance = -1; break;
        case 1:
            distance = 1; break;
        case 2:
            distance = 10; break;
        case 3:
            distance = 50; break;
        case 4:
            distance = 100; break;
        case 5:
            distance = 500; break;
    }
    [GLManager sharedManager].discardPointsWithinDistance = distance;
}

- (IBAction)discardPointsWithinSecondsWasChanged:(UISegmentedControl *)sender {
    int seconds = 1;
    switch(sender.selectedSegmentIndex) {
        case 0:
            seconds = 1; break;
        case 1:
            seconds = 5; break;
        case 2:
            seconds = 10; break;
        case 3:
            seconds = 30; break;
        case 4:
            seconds = 60; break;
        case 5:
            seconds = 120; break;
    }
    [GLManager sharedManager].discardPointsWithinSeconds = seconds;
}

- (IBAction)activityTypeControlWasChanged:(UISegmentedControl *)sender {
    [GLManager sharedManager].activityType = sender.selectedSegmentIndex + 1; // activityType is an enum starting at 1
}

- (IBAction)desiredAccuracyWasChanged:(UISegmentedControl *)sender {
    CLLocationAccuracy d = -999;
    switch(sender.selectedSegmentIndex) {
        case 0:
            d = kCLLocationAccuracyBestForNavigation; break;
        case 1:
            d = kCLLocationAccuracyBest; break;
        case 2:
            d = kCLLocationAccuracyNearestTenMeters; break;
        case 3:
            d = kCLLocationAccuracyHundredMeters; break;
        case 4:
            d = kCLLocationAccuracyKilometer; break;
        case 5:
            d = kCLLocationAccuracyThreeKilometers; break;
    }
    if(d != -999)
        [GLManager sharedManager].desiredAccuracy = d;
}

- (IBAction)pointsPerBatchWasChanged:(UISegmentedControl *)sender {
    int pointsPerBatch = 50;
    switch(sender.selectedSegmentIndex) {
        case 0:
            pointsPerBatch = 50; break;
        case 1:
            pointsPerBatch = 100; break;
        case 2:
            pointsPerBatch = 200; break;
        case 3:
            pointsPerBatch = 500; break;
        case 4:
            pointsPerBatch = 1000; break;        
    }
    [GLManager sharedManager].pointsPerBatch = pointsPerBatch;
}

- (IBAction)toggleNotificationsEnabled:(UISwitch *)sender {
    if(sender.on) {
        [[GLManager sharedManager] requestNotificationPermission];
    } else {
        [GLManager sharedManager].notificationsEnabled = NO;
    }
}

- (IBAction)privacyPolicyWasPressed:(UIButton *)sender {
    NSURL *url = [NSURL URLWithString:@"https://overland.p3k.app/privacy"];
    SFSafariViewController *safariViewController = [[SFSafariViewController alloc] initWithURL:url];
    // safariViewController.delegate = self;
    [self presentViewController:safariViewController animated:YES completion:nil];
}

@end
