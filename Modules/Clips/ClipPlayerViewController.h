#import <UIKit/UIKit.h>

@class ClipsNotesStore;
@class ClipsSectionsStore;

/// Full-screen player for one cached clip: play/pause, scrub, skip +-5s, loop,
/// speed steps (remembered per clip, pitch preserved), time-stamped notes and
/// editable named sections (tap one to play it; with loop on it loops just that
/// section). `sectionReference` (id or 1-based position, may be nil) starts
/// playback on that section.
@interface ClipPlayerViewController : UIViewController

- (instancetype)initWithClipID:(NSString *)clipID
                         title:(NSString *)title
                       fileURL:(NSURL *)fileURL
                         notes:(ClipsNotesStore *)notes
                      sections:(ClipsSectionsStore *)sections
              sectionReference:(NSString *)sectionReference;

@end
