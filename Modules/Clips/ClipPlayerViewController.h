#import <UIKit/UIKit.h>

@class ClipsNotesStore;
@class ClipsSectionsStore;

/// Full-screen player for one cached clip: play/pause, scrub, skip +-5s, loop,
/// speed steps (remembered per clip, pitch preserved), time-stamped notes and
/// editable named sections (tap one to play it; with loop on it loops just that
/// section). The mic button pauses and takes a spoken note or section
/// (ClipsVoiceCommand). `sectionReference` (id or 1-based position, may be nil)
/// starts playback on that section. `scoreURL` is the cached sheet music, nil when there is none.
@interface ClipPlayerViewController : UIViewController

- (instancetype)initWithClipID:(NSString *)clipID
                         title:(NSString *)title
                       fileURL:(NSURL *)fileURL
                      scoreURL:(NSURL *)scoreURL
                         notes:(ClipsNotesStore *)notes
                      sections:(ClipsSectionsStore *)sections
              sectionReference:(NSString *)sectionReference;

@end
