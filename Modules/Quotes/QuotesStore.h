// Owns the Quotes tab's single JSON document -- see the class doc below for
// the schema and QuotesModels.h for GLQuote/GLQuoteRule. There is no App
// Group (App Store Connect's API cannot create one for this app); instead
// the document lives in ONE shared-keychain generic-password item that both
// this app target and, in Stage 2, the JournalControl widget extension read
// -- both targets' provisioning profiles already allow the
// `J66WVM2DTX.*` keychain access group. See Overland.entitlements'
// `keychain-access-groups` entry.

#import <Foundation/Foundation.h>

#import "QuotesModels.h"

NS_ASSUME_NONNULL_BEGIN

/// NSError domain for keychain-unavailable conditions (see `unavailableError`
/// and every write method's `error:` out param below).
extern NSString *const QuotesStoreErrorDomain;

typedef NS_ENUM(NSInteger, QuotesStoreErrorCode) {
    /// SecItem returned errSecMissingEntitlement (-34018): this process has
    /// no keychain-access-groups entitlement for the shared store, so the
    /// document could not be read or the write could not be committed. Not a
    /// corrupt store -- an unsigned build (CI's sim-test.yml) or, on a real
    /// device, a provisioning mismatch. userInfo[NSLocalizedDescriptionKey]
    /// carries a message safe to show the user directly.
    QuotesStoreErrorCodeUnavailable = 1,
};

@interface QuotesStore : NSObject

/// The production store, reading/writing the real keychain item (service
/// com.oliverullman.assistantlocation.quotes, account "store", access group
/// J66WVM2DTX.com.oliverullman.assistantlocation.quotes).
+ (instancetype)sharedStore;

/// Test seam: an isolated store using its own service/account so a test
/// never touches the production keychain item, and can pass `accessGroup`
/// nil to use the running bundle's own default keychain group (a test
/// bundle has no `J66WVM2DTX.*` entitlement of its own).
- (instancetype)initWithService:(NSString *)service
                          account:(NSString *)account
                      accessGroup:(nullable NSString *)accessGroup NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

#pragma mark - The one load/save pair that touches the keychain

/// Set by -loadData the moment it observes errSecMissingEntitlement, cleared
/// the moment a load succeeds (including the errSecItemNotFound "fresh
/// install" case). The Quotes tab reads this after every load and shows a
/// persistent banner above the (still-browsable, stock-only) content while
/// it is non-nil, rather than surfacing the error only via a log line a user
/// never sees.
@property(nonatomic, strong, readonly, nullable) NSError *unavailableError;

/// Raw persisted document: `{"version":1,"quotes":[...imported quotes
/// only...],"rules":[...],"defaultRotateMinutes":N}`. Stock quotes are
/// never written here -- they ship in stock-quotes.json and are merged in
/// live by -allQuotes. Returns nil when nothing has been saved yet (fresh
/// install) -- that is the normal empty state, not an error -- OR when the
/// keychain entitlement is missing, in which case `unavailableError` is set;
/// check it to tell the two apart. Any other keychain failure (a real
/// OSStatus error, or an item that fails to parse as JSON) still raises --
/// no silent fallback to an empty document there, since that would look
/// identical to "fresh install" and could quietly discard a write that
/// actually landed.
- (nullable NSDictionary<NSString *, id> *)loadData;

/// Replaces the keychain item's contents with `data` (SecItemUpdate if the
/// item exists, SecItemAdd otherwise). Returns NO and sets `error` (domain
/// QuotesStoreErrorDomain, code QuotesStoreErrorCodeUnavailable, a message
/// safe to show directly) when the write could not be committed because the
/// keychain entitlement is missing -- the caller must surface this to the
/// user rather than treat the change as saved. Any other SecItem failure
/// still raises, logged with its OSStatus first, per the class doc above.
- (BOOL)saveData:(NSDictionary<NSString *, id> *)data error:(NSError **)error;

#pragma mark - Quotes

/// Bundled stock-quotes.json merged with the persisted document's imported
/// quotes, by id (an id collision -- never expected, since stock ids are
/// "stock-NNN" and imported ids are UUIDs -- lets the imported entry win).
/// Stock quotes keep their bundle order; imported quotes follow, in the
/// order they were saved.
- (NSArray<GLQuote *> *)allQuotes;

/// Every author/genre actually present across -allQuotes, sorted, for the
/// Browse filter and the rule editor's author/genre pickers.
- (NSArray<NSString *> *)knownAuthors;
- (NSArray<NSString *> *)knownGenres;

/// Appends `quotes` (source GLQuoteSourceImported) to the persisted
/// document and saves. Caller is responsible for dedup -- see
/// QuotesImportParser's +normalizeTextForDedupe:. Returns NO/sets `error`
/// exactly as -saveData:error: -- the caller must not report the import as
/// successful when this returns NO.
- (BOOL)addImportedQuotes:(NSArray<GLQuote *> *)quotes error:(NSError **)error;

- (BOOL)deleteImportedQuoteWithId:(NSString *)quoteId error:(NSError **)error;

#pragma mark - Rules

- (NSArray<GLQuoteRule *> *)rules;
- (BOOL)saveRules:(NSArray<GLQuoteRule *> *)rules error:(NSError **)error;

- (NSInteger)defaultRotateMinutes;
- (BOOL)setDefaultRotateMinutes:(NSInteger)minutes error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
