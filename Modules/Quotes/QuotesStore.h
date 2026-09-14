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

/// Raw persisted document: `{"version":1,"quotes":[...imported quotes
/// only...],"rules":[...],"defaultRotateMinutes":N}`. Stock quotes are
/// never written here -- they ship in stock-quotes.json and are merged in
/// live by -allQuotes. Returns nil when nothing has been saved yet (fresh
/// install) -- that is the normal empty state, not an error. Any other
/// keychain failure (a real OSStatus error, or an item that fails to parse
/// as JSON) raises -- no silent fallback to an empty document, since that
/// would look identical to "fresh install" and could quietly discard a
/// write that actually landed.
- (nullable NSDictionary<NSString *, id> *)loadData;

/// Replaces the keychain item's contents with `data` (SecItemUpdate if the
/// item exists, SecItemAdd otherwise). Raises on any SecItem failure --
/// logged with its OSStatus first, per the class doc above.
- (void)saveData:(NSDictionary<NSString *, id> *)data;

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
/// QuotesImportParser's +normalizeTextForDedupe:.
- (void)addImportedQuotes:(NSArray<GLQuote *> *)quotes;

- (void)deleteImportedQuoteWithId:(NSString *)quoteId;

#pragma mark - Rules

- (NSArray<GLQuoteRule *> *)rules;
- (void)saveRules:(NSArray<GLQuoteRule *> *)rules;

- (NSInteger)defaultRotateMinutes;
- (void)setDefaultRotateMinutes:(NSInteger)minutes;

@end

NS_ASSUME_NONNULL_END
