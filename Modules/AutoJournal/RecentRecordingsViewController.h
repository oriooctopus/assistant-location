// Pushed from AutoJournalViewController's nav-bar "Recent" button: lists past
// voice/text journal recordings fetched from GET /journal/recordings, each
// row showing when it was saved and its transcript (or a placeholder while
// ASR is still running / found no words). A nav-bar toggle switches every row
// between the cleaned transcript (default) and the raw one, falling back to
// raw when cleanup failed for that row. Read-only — no upload/record logic
// lives here, that stays in AutoJournalViewController.

#import <UIKit/UIKit.h>

/// Persists the Clean/Raw transcript toggle. Declared here (not
/// GLDefaultsKeys.h) since it belongs to AutoJournal alone -- see the
/// GL*DefaultsName convention in GLTheme.h / GLManager.h -- but exported
/// from the header, rather than kept `static` inside the .m, so
/// Modules/WebBridge/GLWebBridge.m's getPref/setPref "cleanTranscripts"
/// whitelist entry can reference the exact same symbol instead of
/// duplicating the raw string.
static NSString *const GLJournalCleanedTranscriptsDefaultsName = @"GLJournalCleanedTranscriptsDefaults";

@interface RecentRecordingsViewController : UITableViewController
@end
