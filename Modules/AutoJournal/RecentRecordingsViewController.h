// Pushed from AutoJournalViewController's nav-bar "Recent" button: lists past
// voice/text journal recordings fetched from GET /journal/recordings, each
// row showing when it was saved and its transcript (or a placeholder while
// ASR is still running / found no words). A nav-bar toggle switches every row
// between the cleaned transcript (default) and the raw one, falling back to
// raw when cleanup failed for that row. Read-only — no upload/record logic
// lives here, that stays in AutoJournalViewController.

#import <UIKit/UIKit.h>

@interface RecentRecordingsViewController : UITableViewController
@end
