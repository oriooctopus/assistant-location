//
//  FirstViewController.h
//  App
//
//  Created by Aaron Parecki on 9/17/15.
//  Copyright © 2015 Esri. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <MapKit/MapKit.h>

@interface TrackingViewController : UIViewController <MKMapViewDelegate, UIGestureRecognizerDelegate>

@property BOOL usesMetricSystem;

/* Container for the SEND INTERVAL label + slider. The interval itself is still
   a live setting (set by the server's "set" response); only its on-screen knob
   is hidden, so the outlet exists purely to hide the row. */
@property (strong, nonatomic) IBOutlet UIView *sendIntervalView;
@property (strong, nonatomic) IBOutlet UISlider *sendIntervalSlider;
@property (strong, nonatomic) IBOutlet UILabel *sendIntervalLabel;
@property (strong, nonatomic) IBOutlet UIButton *sendNowButton;

@property (strong, nonatomic) IBOutlet UILabel *locationLabel;
@property (strong, nonatomic) IBOutlet UILabel *locationSpeedLabel;
@property (strong, nonatomic) IBOutlet UILabel *locationSpeedUnitLabel;
@property (strong, nonatomic) IBOutlet UILabel *locationAltitudeLabel;
@property (strong, nonatomic) IBOutlet UILabel *locationAgeLabel;

@property (strong, nonatomic) IBOutlet UILabel *motionTypeLabel;

@property (strong, nonatomic) IBOutlet UILabel *queueLabel;
@property (strong, nonatomic) IBOutlet UILabel *queueAgeLabel;

- (IBAction)sendIntervalDragged:(UISlider *)sender;
- (IBAction)sendIntervalChanged:(UISlider *)sender;
- (IBAction)sendQueue:(id)sender;
- (IBAction)locationAgeWasTapped:(id)sender;
- (IBAction)locationCoordinatesWasTapped:(UILongPressGestureRecognizer *)sender;

@property (strong, nonatomic) IBOutlet MKMapView *mapView;

@end
