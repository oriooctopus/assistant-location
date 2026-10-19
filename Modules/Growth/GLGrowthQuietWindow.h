// Pure quiet-window bookkeeping for GrowthModule, split out (same pattern as
// GLEsmeReminderScheduling) so the "max, never shortens" rule can be unit
// tested with an injected NSUserDefaults suite and clock -- GrowthModule
// itself drags in GrowthViewController and the module registry.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Window a plain review (a card answer) buys: 30 minutes.
extern NSTimeInterval const GLGrowthDefaultQuietSeconds;

@interface GLGrowthQuietWindow : NSObject

/// Stores quiet-until = max(existing quiet-until, now + quietSeconds), so a
/// short window never shortens a longer one already running (a 30-minute card
/// answer inside a 4-hour tile-pick window). A nil quietSeconds means
/// GLGrowthDefaultQuietSeconds. Also drops the pre-quiet-until
/// "GLGrowthLastReviewedAt" key, which is ignored from now on.
+ (void)noteReviewWithQuietSeconds:(nullable NSNumber *)quietSeconds
                          defaults:(NSUserDefaults *)defaults
                               now:(NSTimeInterval)now;

/// YES while now < the stored quiet-until. NO if none was ever stored.
+ (BOOL)isQuietInDefaults:(NSUserDefaults *)defaults now:(NSTimeInterval)now;

@end

NS_ASSUME_NONNULL_END
