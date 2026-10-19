#import "GLGrowthQuietWindow.h"

// Stored as an NSTimeInterval (-timeIntervalSinceReferenceDate), not an
// NSDate, so a plain -doubleForKey:/-setDouble:forKey: round-trip is enough.
static NSString *const kQuietUntilKey = @"GLGrowthQuietUntil";
// Superseded by kQuietUntilKey; read by nothing, removed on the next write.
static NSString *const kLegacyLastReviewedAtKey = @"GLGrowthLastReviewedAt";

// "show every 30 mins" (Oliver, 2026-10-11) -- his own number, not tuned.
NSTimeInterval const GLGrowthDefaultQuietSeconds = 30 * 60;

@implementation GLGrowthQuietWindow

+ (void)noteReviewWithQuietSeconds:(NSNumber *)quietSeconds
                          defaults:(NSUserDefaults *)defaults
                               now:(NSTimeInterval)now {
    NSTimeInterval seconds = quietSeconds ? quietSeconds.doubleValue : GLGrowthDefaultQuietSeconds;
    NSTimeInterval until = MAX([defaults doubleForKey:kQuietUntilKey], now + seconds);
    [defaults setDouble:until forKey:kQuietUntilKey];
    [defaults removeObjectForKey:kLegacyLastReviewedAtKey];
}

+ (BOOL)isQuietInDefaults:(NSUserDefaults *)defaults now:(NSTimeInterval)now {
    // Unset reads 0 (2001-01-01), which is never in the future, so a user who
    // never reviewed gets NO.
    return now < [defaults doubleForKey:kQuietUntilKey];
}

@end
