// The Journal tab: record a voice note (AVAudioRecorder, AAC .m4a) or type a
// short text entry, then upload either to the drop server (see
// GLDropUploader). Also the landing point for the lock-screen "Record Journal
// Entry" Control (JournalControl/ at the repo root): that Control's
// StartJournalIntent runs in-app (openAppWhenRun) and posts the
// GLJournalStartCapture notification, which this view controller observes to
// select this tab and start recording automatically.

#import <UIKit/UIKit.h>

@interface AutoJournalViewController : UIViewController
@end
