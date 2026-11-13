#import <Foundation/Foundation.h>

/// The app's whole state as one JSON file, `state.json`, in the App Group container shared with the
/// widget (ListsWidget reads it). The page owns the schema; this class only moves the bytes.
@interface ListsStateStore : NSObject

/// The stored state parsed as a JSON object, or nil with *error left nil when no state file exists
/// yet (first launch). A file that exists but cannot be read or parsed sets *error.
- (NSDictionary *)loadStateError:(NSError **)error;

/// Writes `state` atomically (a reader never sees a half-written file), then asks WidgetKit to
/// reload every timeline so the widget shows the new data.
- (BOOL)saveState:(NSDictionary *)state error:(NSError **)error;

@end
