#import <UIKit/UIKit.h>

@class ClipsNotesStore;
@class ClipsSectionsStore;
@class ClipsTakesStore;

/// Full-screen player for one cached clip: play/pause, scrub, skip +-5s, loop,
/// speed steps (remembered per clip, pitch preserved), time-stamped notes and
/// editable named sections (tap one to play it; with loop on it loops just that
/// section). The mic button pauses and takes a spoken note or section
/// (ClipsVoiceCommand). `sectionReference` (id or 1-based position, may be nil)
/// starts playback on that section. `scoreURL` is the cached sheet music, nil when
/// there is none. Record saves a take of the learner playing, which
/// opens in this same player; once the box has placed it in the song, the section
/// highlight follows it and Back to song returns to the matching song moment.
@interface ClipPlayerViewController : UIViewController

- (instancetype)initWithClipID:(NSString *)clipID
                         title:(NSString *)title
                       fileURL:(NSURL *)fileURL
                      scoreURL:(NSURL *)scoreURL
                         notes:(ClipsNotesStore *)notes
                      sections:(ClipsSectionsStore *)sections
                         takes:(ClipsTakesStore *)takes
              sectionReference:(NSString *)sectionReference;

@end
