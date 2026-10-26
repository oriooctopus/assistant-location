#import <UIKit/UIKit.h>

@class ClipsNotesStore;

/// Full-screen player for one cached clip: play/pause, scrub, skip +-5s, loop,
/// speed steps (remembered per clip, pitch preserved) and time-stamped notes.
@interface ClipPlayerViewController : UIViewController

- (instancetype)initWithClipID:(NSString *)clipID
                         title:(NSString *)title
                       fileURL:(NSURL *)fileURL
                         notes:(ClipsNotesStore *)notes;

@end
