#import <UIKit/UIKit.h>

@class ClipsNotesStore;
@class ClipsSectionsStore;
@class ClipsTakesStore;

/// Full-screen player for one cached clip: play/pause, scrub, skip +-5s, loop,
/// speed steps (remembered per clip, pitch preserved), time-stamped notes and
/// editable named sections (tap one to play it; with loop on it loops just that
/// section). `sectionReference` (id or 1-based position, may be nil) starts
/// playback on that section. Record saves a take of the learner playing, which
/// opens in this same player; once the box has placed it in the song, the section
/// highlight follows it and Back to song returns to the matching song moment.
@interface ClipPlayerViewController : UIViewController

/// Set before presenting: restore the position without playing, for the Clips tab
/// reopening the last clip on its own (a tab switch should not start music).
@property (nonatomic) BOOL startsPaused;

- (instancetype)initWithClipID:(NSString *)clipID
                         title:(NSString *)title
                       fileURL:(NSURL *)fileURL
                         notes:(ClipsNotesStore *)notes
                      sections:(ClipsSectionsStore *)sections
                         takes:(ClipsTakesStore *)takes
              sectionReference:(NSString *)sectionReference;

@end
