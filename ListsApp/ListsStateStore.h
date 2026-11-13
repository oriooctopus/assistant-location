#import <Foundation/Foundation.h>

/// The app's persistence. The full state is one JSON file, `state.json`, in the app's own
/// Application Support directory (what `loadState` returns to the page). Separately, every save also
/// writes a trimmed snapshot to a shared keychain item that ListsWidget reads (a shared keychain
/// group, the approach the Quotes app and its widget use, needs no portal step). The page owns the schema;
/// this class only moves the bytes and builds the trimmed snapshot.
@interface ListsStateStore : NSObject

/// The stored state parsed as a JSON object, or nil with *error left nil when no state file exists
/// yet (first launch). A file that exists but cannot be read or parsed sets *error.
- (NSDictionary *)loadStateError:(NSError **)error;

/// Writes `state` atomically (a reader never sees a half-written file), writes the trimmed widget
/// snapshot to the keychain, then asks WidgetKit to reload every timeline. NO on the first failure
/// with *error naming the cause (an NSError or an OSStatus); never raises.
- (BOOL)saveState:(NSDictionary *)state error:(NSError **)error;

/// The widget's view of `state`: {v, widgetListId, lists, categories, items} with deleted records
/// and checked items dropped and each item reduced to id, listId, name, note, categoryId, createdAt.
/// Exposed for tests; nil with *error when the state does not have the expected shape.
+ (NSDictionary *)widgetSnapshotFromState:(NSDictionary *)state error:(NSError **)error;

@end
