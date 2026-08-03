// Small formatting helpers. Two near-duplicate duration formatters exist
// today with different edge cases (AutoJournalViewController.m:248-253 does
// mm:ss only and overflows past an hour; TrackingViewController.m:521-540
// mislabels itself "h:mm" but actually prints "hours:minutes", silently
// dropping seconds once past an hour). GLFormatDuration is the one correct
// version — existing call sites are NOT migrated in this pass (later task).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// "mm:ss" below an hour, "h:mm:ss" at or past an hour. `seconds` is clamped
/// to >= 0 (a negative duration is a caller bug, not something to render).
FOUNDATION_EXPORT NSString *GLFormatDuration(NSTimeInterval seconds);

/// "yyyy-MM-dd-HHmmss" in en_US_POSIX, for filenames that embed a capture
/// timestamp (journal notes/recordings, uploaded screenshots).
FOUNDATION_EXPORT NSString *GLFilenameTimestamp(void);

NS_ASSUME_NONNULL_END
