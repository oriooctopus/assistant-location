// Value objects for the Quotes tab's data model. See QuotesStore.h for the
// persisted document shape these serialize to/from ({"version":1,"quotes":
// [...],"rules":[...],"defaultRotateMinutes":N}) and MODULES.md/the Quotes
// brief for the full schema.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// "stock" (shipped in stock-quotes.json) or "imported" (pasted in by the
/// user, persisted in the keychain document). Not an NS_ENUM -- it's
/// serialized verbatim into the JSON document and the widget extension
/// (Stage 2) will read the same raw string.
extern NSString *const GLQuoteSourceStock;
extern NSString *const GLQuoteSourceImported;

/// "filter" (author/genre match against the quote library) or "ai" (a
/// natural-language prompt resolved server-side, Stage 2 -- see
/// QuotesRuleEngine.h).
extern NSString *const GLQuoteRuleKindFilter;
extern NSString *const GLQuoteRuleKindAI;

@interface GLQuote : NSObject <NSCopying>

@property(nonatomic, copy, readonly) NSString *quoteId;
@property(nonatomic, copy, readonly) NSString *text;
@property(nonatomic, copy, readonly) NSString *author;
@property(nonatomic, copy, readonly) NSArray<NSString *> *genres;
@property(nonatomic, copy, readonly) NSString *source; // GLQuoteSourceStock / GLQuoteSourceImported

- (instancetype)initWithId:(NSString *)quoteId
                       text:(NSString *)text
                     author:(NSString *)author
                     genres:(NSArray<NSString *> *)genres
                     source:(NSString *)source NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Parses one quote from its wire/on-disk dictionary. Returns nil (and never
/// partially constructs) if `id`/`text`/`author` are missing or the wrong
/// type -- a malformed entry is dropped by the caller, never silently
/// coerced into an empty string.
+ (nullable instancetype)quoteFromDictionary:(id)dictionary;

- (NSDictionary<NSString *, id> *)toDictionary;

@end

@interface GLQuoteRule : NSObject <NSCopying>

@property(nonatomic, copy, readonly) NSString *ruleId;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *kind; // GLQuoteRuleKindFilter / GLQuoteRuleKindAI
@property(nonatomic, copy) NSArray<NSString *> *authors;
@property(nonatomic, copy) NSArray<NSString *> *genres;
@property(nonatomic, copy) NSString *prompt;       // kind == AI only; saved either way
@property(nonatomic, copy) NSArray<NSString *> *quoteIds; // kind == AI, resolved server-side (Stage 2)
@property(nonatomic, copy) NSArray<NSNumber *> *days;     // 1-7, 1 = Sunday (NSCalendar's own convention)
@property(nonatomic, assign) NSInteger startMinute; // 0...1440, inclusive lower bound
@property(nonatomic, assign) NSInteger endMinute;   // 0...1440, exclusive upper bound; < startMinute wraps past midnight
@property(nonatomic, assign) NSInteger rotateMinutes;

- (instancetype)initWithId:(NSString *)ruleId
                       name:(NSString *)name
                       kind:(NSString *)kind
                    authors:(NSArray<NSString *> *)authors
                     genres:(NSArray<NSString *> *)genres
                     prompt:(NSString *)prompt
                   quoteIds:(NSArray<NSString *> *)quoteIds
                       days:(NSArray<NSNumber *> *)days
                startMinute:(NSInteger)startMinute
                  endMinute:(NSInteger)endMinute
              rotateMinutes:(NSInteger)rotateMinutes NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

+ (nullable instancetype)ruleFromDictionary:(id)dictionary;
- (NSDictionary<NSString *, id> *)toDictionary;

/// YES if `minuteOfDay` (0...1439) falls in [startMinute, endMinute), treating
/// endMinute < startMinute as a window that wraps past midnight (e.g.
/// start=1320 end=360 covers 22:00 through 06:00). endMinute == startMinute
/// is treated as covering the WHOLE day (24h span), not an empty window --
/// the only way to express "always" with a half-open interval.
- (BOOL)containsWeekday:(NSInteger)weekday minuteOfDay:(NSInteger)minuteOfDay;

@end

NS_ASSUME_NONNULL_END
