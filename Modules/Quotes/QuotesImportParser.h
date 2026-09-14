// Parses text pasted into the Import screen into quote/author pairs, ahead
// of showing the user a preview. Pure and stateless -- no store access, no
// UIKit -- so it's directly unit-testable.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface QuotesParsedQuote : NSObject
@property(nonatomic, copy, readonly) NSString *text;
@property(nonatomic, copy, readonly) NSString *author; // "Unknown" when none was recognized
- (instancetype)initWithText:(NSString *)text author:(NSString *)author NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface QuotesImportParser : NSObject

/// Splits `input` into candidate entries -- one per line if the input has no
/// blank lines, otherwise one per blank-line-separated block (a block's
/// internal newlines are joined with a space, so a quote pasted wrapped
/// across several lines survives as one entry) -- then parses each with
/// -parseOneEntry:. Entries that parse to empty text are dropped. Does NOT
/// dedupe; see +normalizeTextForDedupe: for the caller to do that itself
/// against both this batch and the existing store.
+ (NSArray<QuotesParsedQuote *> *)parseText:(NSString *)input;

/// Parses a single line/block. Recognizes, in order:
///   1. A quoted-or-plain text followed by a dash/tilde separator and an
///      author: `"text" — Author`, `text - Author`, `text ~ Author`, with
///      straight or curly quotes and -/–/—/~ as the separator.
///   2. CSV: `text,author` (exactly one comma, no quote-delimited text).
///   3. Neither -- the whole trimmed line is the text, author "Unknown".
+ (QuotesParsedQuote *)parseOneEntry:(NSString *)entry;

/// Lowercased, punctuation- and whitespace-normalized form of `text`, for
/// dedupe comparisons (both within an import batch and against quotes
/// already in the store).
+ (NSString *)normalizeTextForDedupe:(NSString *)text;

@end

NS_ASSUME_NONNULL_END
