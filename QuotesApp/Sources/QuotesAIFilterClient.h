// Native client for the location server's AI-filter route (an AI-kind
// GLQuoteRule's prompt -> a set of matching quote ids, resolved server-side
// since this app bakes no LLM credentials of its own). See
// QuotesRuleEditViewController for when this is called (on save of a
// new/changed prompt, and from a manual "Re-run" button).

#import <Foundation/Foundation.h>

#import "QuotesModels.h"

NS_ASSUME_NONNULL_BEGIN

/// Exactly one of the two is non-nil. `quoteIds` can legitimately be an
/// empty array (the prompt matched nothing) -- that is still a success, not
/// an error.
typedef void (^QuotesAIFilterCompletion)(NSArray<NSString *> *_Nullable quoteIds, NSString *_Nullable errorMessage);

@interface QuotesAIFilterClient : NSObject

/// POSTs `{"prompt": prompt, "quotes": [{"id","text","author","genres"}, ...]}`
/// (capped at 1000 quotes, the route's documented limit) to
/// `/quotes/ai-filter` with the app's baked Bearer token, and reports the
/// resolved `quoteIds` on a 200, or a human-readable error message on any
/// other status/transport failure. Always calls back on the main queue.
/// No retry -- a caller that wants another attempt (a manual "Re-run", or
/// a changed prompt) calls this again itself.
+ (void)resolvePrompt:(NSString *)prompt
        againstQuotes:(NSArray<GLQuote *> *)quotes
           completion:(QuotesAIFilterCompletion)completion;

@end

NS_ASSUME_NONNULL_END
