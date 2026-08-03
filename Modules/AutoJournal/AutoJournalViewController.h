// The Journal tab: record a voice note (AVAudioRecorder, AAC .m4a) or type a
// short text entry, then upload either to the drop server (see
// GLDropUploader). Also the landing point for the lock-screen "Record Journal
// Entry" Control (JournalControl/ at the repo root): that Control writes
// GLJournalPendingCapture=YES into the shared app group's NSUserDefaults and
// launches the app; this view controller notices that flag on
// UIApplicationDidBecomeActiveNotification, selects this tab, and starts
// recording automatically.

#import <UIKit/UIKit.h>

@interface AutoJournalViewController : UIViewController
@end
