//
//  FirstViewController.m
//  GPSLogger
//
//  Created by Aaron Parecki on 9/17/15.
//  Copyright © 2015 Esri. All rights reserved.
//  Copyright © 2017 Aaron Parecki. All rights reserved.
//

#import "TrackingViewController.h"
#import "GLManager.h"
// Written by the "Generate build stamp" run-script phase on every build.
#import "BuildStamp.generated.h"

@interface TrackingViewController ()

@property (strong, nonatomic) NSTimer *viewRefreshTimer;
@property (strong, nonatomic) UILabel *sendStatusLabel;

@end

@implementation TrackingViewController

NSArray *intervalMap;
NSArray *intervalMapStrings;
MKPointAnnotation *currentLocationAnnotation;
BOOL dragInProgress = NO;
BOOL mapWasDragged = NO;

- (void)registerUserActivity {
    NSString *bundleIDStarter = [NSString stringWithFormat:@"%@.startTracking", [[NSBundle mainBundle] bundleIdentifier]];
    
    NSUserActivity *activityStart = [[NSUserActivity alloc] initWithActivityType:bundleIDStarter];
    activityStart.title = @"Start Overland Tracking";
    activityStart.userInfo = @{@"tracking" : @"on"};
    [activityStart setEligibleForSearch:true];
    if (@available(iOS 12.0, *)) {
        [activityStart setEligibleForPrediction:true];
    }
    self.view.userActivity = activityStart;
    [activityStart becomeCurrent];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    intervalMap = @[@1, @5, @10, @15, @30, @60, @120, @300, @600, @1800, @-1];
    intervalMapStrings = @[@"1s", @"5s", @"10s", @"15s", @"30s", @"1m", @"2m", @"5m", @"10m", @"30m", @"off"];
    
    //    [[GLManager sharedManager] accountInfo:^(NSString *name) {
    //        self.accountInfo.text = name;
    //    }];
    
    UIImage *pattern = [UIImage imageNamed:@"topobkg"];
    self.view.backgroundColor = [UIColor colorWithPatternImage:pattern];

    // Assistant fork: the outcome of the last send was only ever a notification,
    // so a queue that stopped draining looked identical to one that was empty.
    // Keep the last attempt's time and result on screen.
    self.sendStatusLabel = [[UILabel alloc] init];
    self.sendStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.sendStatusLabel.font = [UIFont systemFontOfSize:11];
    self.sendStatusLabel.textColor = [UIColor whiteColor];
    self.sendStatusLabel.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.55];
    self.sendStatusLabel.textAlignment = NSTextAlignmentCenter;
    self.sendStatusLabel.adjustsFontSizeToFitWidth = YES;
    self.sendStatusLabel.minimumScaleFactor = 0.7;
    [self.view addSubview:self.sendStatusLabel];
    // Overlaid on the top edge of the map, which is empty. Under the build
    // banner it would cover the storyboard's AGE / LOCATION / MPH row, and at
    // the bottom safe area it would cover the Apple Maps attribution.
    [NSLayoutConstraint activateConstraints:@[
        [self.sendStatusLabel.topAnchor constraintEqualToAnchor:self.mapView.topAnchor],
        [self.sendStatusLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.sendStatusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.sendStatusLabel.heightAnchor constraintEqualToConstant:20],
    ]];
    [self updateSendStatusLabel];

    // Assistant fork: this is a single-purpose background tracker, so the
    // screen shows status only — no knobs. This row is an arranged subview of
    // a UIStackView, so hiding it collapses it with no layout gap. It stays in
    // the hierarchy (rather than being deleted from the storyboard) because
    // sibling constraints anchor to it, and because the setting it showed is
    // still live: the send interval is set by the server's "set" response.
    self.sendIntervalView.hidden = YES;

    [self.sendNowButton.layer setCornerRadius:4.0];
    [self setNeedsStatusBarAppearanceUpdate];
    
    // adding Shortcut Code
    // get Bundle ID and add ...
    [self registerUserActivity];
    
    UIPanGestureRecognizer *panRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(didDragMap:)];
    [panRecognizer setDelegate:self];
    [self.mapView addGestureRecognizer:panRecognizer];
    
    CLLocation *lastLocation = [GLManager sharedManager].lastLocation;
    self.mapView.showsUserLocation = NO;
    self.mapView.camera.centerCoordinate = lastLocation.coordinate;
    self.mapView.camera.altitude = [self mapAltitude];
    self.mapView.zoomEnabled = YES;
    
    currentLocationAnnotation = [[MKPointAnnotation alloc] initWithCoordinate:lastLocation.coordinate];
    [self.mapView addAnnotation:currentLocationAnnotation];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}


- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // Assistant fork: request location permission here (not at launch). The
    // dialog only presents when the app is actually foreground-active, so a
    // didFinishLaunching request silently no-ops — which is why permission had
    // to be granted manually from the Settings tab. Firing it once the main
    // screen is on-screen makes the prompt appear on first open, no Settings
    // visit needed. requestAuthorizationPermission asks WhenInUse first, then
    // Always for background logging.
    [[GLManager sharedManager] requestAuthorizationPermission];
}

- (void)viewWillAppear:(BOOL)animated {
    [self sendingFinished];

    [self updateVisibleSettings];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(newDataReceived)
                                                 name:GLNewDataNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(newActivityReceived)
                                                 name:GLNewActivityNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateVisibleSettings)
                                                 name:GLSettingsChangedNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sendingStarted)
                                                 name:GLSendingStartedNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(sendingFinished)
                                                 name:GLSendingFinishedNotification
                                               object:nil];

    self.viewRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                             target:self
                                                           selector:@selector(refreshView)
                                                           userInfo:nil
                                                            repeats:YES];

    NSLocale *locale = [NSLocale currentLocale];
    self.usesMetricSystem = [[locale objectForKey:NSLocaleUsesMetricSystem] boolValue];
}

- (void)updateVisibleSettings {
    if([GLManager sharedManager].sendingInterval) {
        self.sendIntervalSlider.value = [intervalMap indexOfObject:[GLManager sharedManager].sendingInterval];
        [self updateSendIntervalLabel];
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    [self.viewRefreshTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillDisappear:(BOOL)animated {
    [UIApplication sharedApplication].idleTimerDisabled = NO;
}

- (void)dealloc {
    NSLog(@"view is deallocd");
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - MKMapViewDelegate

- (MKAnnotationView * _Nullable)mapView:(MKMapView *)mapView viewForAnnotation:(nonnull id<MKAnnotation>)annotation {
    MKAnnotationView *annotationView = [mapView dequeueReusableAnnotationViewWithIdentifier:@"current"];
    if(annotationView == nil) {
        annotationView = [[MKAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:@"current"];
    } else {
        annotationView.annotation = annotation;
    }
    annotationView.image = [UIImage imageNamed:@"map-dot"];
    return annotationView;
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (void)didDragMap:(UIGestureRecognizer *)gestureRecognizer {
//    [UIView setAnimationsEnabled:NO];
    if(gestureRecognizer.state == UIGestureRecognizerStateBegan) {
        dragInProgress = YES;
        mapWasDragged = YES;
    }
    if(gestureRecognizer.state == UIGestureRecognizerStateEnded) {
        dragInProgress = NO;
    }
}

#pragma mark - Tracking Interface

- (void)newDataReceived {
    self.locationAgeLabel.textColor = [UIColor whiteColor];
    [self refreshView];
    [self updateMap];
}

- (void)newActivityReceived {
    [self refreshView];
}

- (void)sendingStarted {
    self.sendNowButton.titleLabel.text = @"Sending...";
    self.sendNowButton.backgroundColor = [UIColor colorNamed:@"OverlandGreenSecondary"];
    self.sendNowButton.enabled = NO;
}

- (void)sendingFinished {
    self.sendNowButton.titleLabel.text = @"Send Now";
    if([[GLManager sharedManager] apiEndpointURL] == nil) {
        self.sendNowButton.backgroundColor = [UIColor colorNamed:@"OverlandGreenSecondary"];
        self.sendNowButton.enabled = NO;
    } else {
        self.sendNowButton.backgroundColor = [UIColor colorNamed:@"OverlandGreen"];
        self.sendNowButton.enabled = YES;
    }
}

- (NSString *)speedUnitText {
    if(self.usesMetricSystem) {
        return @"KM/H";
    } else {
        return @"MPH";
    }
}

- (void)updateMap {
    CLLocation *location = [GLManager sharedManager].lastLocation;

    // Determine if the current location too close to the edge of the map
    MKMapPoint point = MKMapPointForCoordinate(location.coordinate);
    UIEdgeInsets insets = UIEdgeInsetsMake(-50, -50, -50, -50);
    MKMapRect smallerRect = [self.mapView mapRectThatFits:self.mapView.visibleMapRect edgePadding:insets];
    BOOL outOfBounds = !MKMapRectContainsPoint(smallerRect, point);

    // Pan the map if the map is not currently being dragged and the point is near the edge
    MKMapCamera *camera;
    if(outOfBounds && !dragInProgress) {
        if(outOfBounds) {
            // Reset
            mapWasDragged = NO;
        }
        camera = [[MKMapCamera alloc] init];
        camera.centerCoordinate = location.coordinate;
        // camera.altitude = [self mapAltitude];
        camera.altitude = self.mapView.camera.altitude;
    }

    if(camera != nil) {
        [self.mapView setCamera:camera animated:YES];
    }

    [UIView animateWithDuration:1 delay:0 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        currentLocationAnnotation.coordinate = location.coordinate;
    } completion:^(BOOL finished) {
        if(!finished) {
            currentLocationAnnotation.coordinate = location.coordinate;
        }
    }];
}

- (int)mapAltitude {
    int altitude;
    NSString *m = [GLManager sharedManager].currentTripMode;
    if([m isEqualToString:@"walk"] || [m isEqualToString:@"run"] || [m isEqualToString:@"bicycle"] || [m isEqualToString:@"scooter"]) {
        altitude = 1000;
    } else {
        altitude = 3000;
    }
    return altitude;
}

- (void)refreshView {
    CLLocation *location = [GLManager sharedManager].lastLocation;
    self.locationLabel.text = [NSString stringWithFormat:@"%-4.4f\n%-4.4f", location.coordinate.latitude, location.coordinate.longitude];
    self.locationAltitudeLabel.text = [NSString stringWithFormat:@"+/-%dm %dm", (int)round(location.horizontalAccuracy), (int)round(location.altitude)];

    int speed;
    if(self.usesMetricSystem) {
        speed = (int)(round(location.speed*3.6));
    } else {
        speed = (int)(round(location.speed*2.23694));
    }
    if(speed < 0) speed = 0;
    self.locationSpeedLabel.text = [NSString stringWithFormat:@"%d", speed];

    int age = -(int)round([GLManager sharedManager].lastLocation.timestamp.timeIntervalSinceNow);
    if(age == 1) age = 0;
    self.locationAgeLabel.text = [TrackingViewController timeFormatted:age];
    
    NSString *motionTypeString;
    CMMotionActivity *activity = [GLManager sharedManager].lastMotion;
    if(activity.walking)
        motionTypeString = @"walking";
    else if(activity.running)
        motionTypeString = @"running";
    else if(activity.cycling)
        motionTypeString = @"cycling";
    else if(activity.automotive)
        motionTypeString = @"driving";
    else if(activity.stationary)
        motionTypeString = @"stationary";
    else {
        if([GLManager sharedManager].lastMotionString)
            motionTypeString = [GLManager sharedManager].lastMotionString;
        else
            motionTypeString = nil;
    }

    if(motionTypeString != nil) {
        self.motionTypeLabel.text = motionTypeString;
    } else {
        self.motionTypeLabel.text = @"";
    }
    
    self.locationSpeedUnitLabel.text = [self speedUnitText];

    if([GLManager sharedManager].lastSentDate) {
        age = -(int)round([GLManager sharedManager].lastSentDate.timeIntervalSinceNow);
        self.queueAgeLabel.text = [NSString stringWithFormat:@"%@", [TrackingViewController timeFormatted:age]];
    } else {
        self.queueAgeLabel.text = @"n/a";
    }
    
    [[GLManager sharedManager] numberOfLocationsInQueue:^(long num) {
        self.queueLabel.text = [NSString stringWithFormat:@"%ld", num];
    }];

    [self updateSendStatusLabel];
}

- (void)updateSendStatusLabel {
    NSDate *attempt = [GLManager sharedManager].lastSendAttemptDate;
    NSString *send;
    if(attempt == nil) {
        send = @"last send: none yet";
    } else {
        static NSDateFormatter *formatter = nil;
        if(formatter == nil) {
            formatter = [[NSDateFormatter alloc] init];
            formatter.dateFormat = @"HH:mm:ss";
        }
        send = [NSString stringWithFormat:@"last send %@: %@",
                [formatter stringFromDate:attempt],
                [GLManager sharedManager].lastSendStatus];
    }
    // The build stamp shares this strip rather than getting its own banner:
    // this one is known to render on device, the separate top banner was not.
    self.sendStatusLabel.text = [NSString stringWithFormat:@"b%@ · %@",
                                 GL_BUILD_STAMP, send];
}

- (IBAction)sendQueue:(id)sender {
    [[GLManager sharedManager] sendQueueNow];
}

- (void)updateSendIntervalLabel {
    NSString *val = intervalMapStrings[(int)roundf([self.sendIntervalSlider value])];
    self.sendIntervalLabel.text = val;
}

- (IBAction)sendIntervalDragged:(UISlider *)sender {
    // Snap to whole numbers
    sender.value = roundf([sender value]);
    [self updateSendIntervalLabel];
}

- (IBAction)sendIntervalChanged:(UISlider *)sender {
    sender.value = roundf([sender value]);
    NSNumber *val = intervalMap[(int)roundf([self.sendIntervalSlider value])];
    if([GLManager sharedManager].sendingInterval != val) {
        [self updateSendIntervalLabel];
        [GLManager sharedManager].sendingInterval = val;
    }
}

- (IBAction)locationAgeWasTapped:(id)sender {
    self.locationAgeLabel.textColor = [UIColor colorWithRed:(210.f/255.f) green:(30.f/255.f) blue:(30.f/255.f) alpha:1];
    [[GLManager sharedManager] refreshLocation];
}

- (IBAction)locationCoordinatesWasTapped:(UILongPressGestureRecognizer *)sender {
    if(sender.state == UIGestureRecognizerStateBegan) {
        CLLocation *location = [GLManager sharedManager].lastLocation;
        NSString *string = [NSString stringWithFormat:@"%.5f,%.5f", location.coordinate.latitude, location.coordinate.longitude];

        UIPasteboard *pb = [UIPasteboard generalPasteboard];
        [pb setString:string];
        NSLog(@"Copied %@", string);

        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Copied"
                                                                       message:string
                                                                preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction* closeAction = [UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleDefault
                                                             handler:^(UIAlertAction * action) {
                                                             }];
        [alert addAction:closeAction];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

#pragma mark -

+ (NSString *)timeFormatted:(int)totalSeconds {
    int seconds = totalSeconds % 60;
    int minutes = (totalSeconds / 60) % 60;
    int hours = totalSeconds / 3600;
    
    if(hours == 0) {
        return [NSString stringWithFormat:@"%d:%02d", minutes, seconds];
    } else {
        return [NSString stringWithFormat:@"%d:%02d", hours, minutes];
    }
}

+ (NSString *)timeUnits:(int)totalSeconds {
    int hours = totalSeconds / 3600;
    if(hours == 0) {
        return @"minutes";
    } else {
        return @"hours";
    }
}

@end
