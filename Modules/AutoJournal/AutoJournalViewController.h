// The Journal tab: record a voice note (AVAudioRecorder, AAC .m4a) or type a
// short text entry, then upload either to the drop server (see
// GLDropUploader). Also the landing point for the lock-screen "Voice
// Journal" / "Text Journal" Controls (JournalControl/ at the repo root):
// those Controls open overland://journal/voice|text, which SceneDelegate
// routes to AutoJournalModule +moduleHandleURL:, which posts the
// GLJournalStartCapture / GLJournalStartTextEntry notification that this
// view controller observes to select this tab and start recording
// automatically. The URL hop is load-bearing — see JournalIntent.swift for
// why an AppIntent posting the notification directly does NOT work.

#import <UIKit/UIKit.h>

@interface AutoJournalViewController : UIViewController
@end
