#import "QuotesAIFilterClient.h"

#import "BakedConfig.h"
#import "GLEndpoints.h"
#import "GLLog.h"

NS_ASSUME_NONNULL_BEGIN

static NSUInteger const kQuotesAIFilterMaxQuotes = 1000;

@implementation QuotesAIFilterClient

+ (void)resolvePrompt:(NSString *)prompt
        againstQuotes:(NSArray<GLQuote *> *)quotes
           completion:(QuotesAIFilterCompletion)completion {
    NSArray<GLQuote *> *capped = quotes.count > kQuotesAIFilterMaxQuotes
        ? [quotes subarrayWithRange:NSMakeRange(0, kQuotesAIFilterMaxQuotes)]
        : quotes;
    NSMutableArray<NSDictionary<NSString *, id> *> *quoteDicts = [NSMutableArray arrayWithCapacity:capped.count];
    for (GLQuote *quote in capped) {
        [quoteDicts addObject:@{
            @"id": quote.quoteId,
            @"text": quote.text,
            @"author": quote.author,
            @"genres": quote.genres,
        }];
    }
    NSDictionary<NSString *, id> *body = @{@"prompt": prompt ?: @"", @"quotes": quoteDicts};

    NSError *jsonError = nil;
    NSData *payload = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError];
    if (jsonError || payload == nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, [NSString stringWithFormat:@"could not build the AI-filter request: %@", jsonError]);
        });
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:GLEndpointURL(@"/quotes/ai-filter")];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", GL_BAKED_TOKEN] forHTTPHeaderField:@"Authorization"];
    request.HTTPBody = payload;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *_Nullable data, NSURLResponse *_Nullable response, NSError *_Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error != nil) {
                completion(nil, error.localizedDescription);
                return;
            }
            NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
                ? ((NSHTTPURLResponse *)response).statusCode : 0;

            if (status == 200) {
                NSError *parseError = nil;
                id parsed = data != nil ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError] : nil;
                id rawIds = [parsed isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)parsed)[@"quoteIds"] : nil;
                if (![rawIds isKindOfClass:[NSArray class]]) {
                    GLLog(@"AI-filter 200 response did not carry a quoteIds array: %@", parseError ?: parsed);
                    completion(nil, @"The server's response didn't include a quoteIds list.");
                    return;
                }
                NSMutableArray<NSString *> *quoteIds = [NSMutableArray arrayWithCapacity:[(NSArray *)rawIds count]];
                for (id entry in (NSArray *)rawIds) {
                    if ([entry isKindOfClass:[NSString class]]) [quoteIds addObject:entry];
                }
                completion(quoteIds, nil); // an empty array here is a valid "matched nothing" answer
                return;
            }

            // 401 responds with a plain-text body; 400/502/503 with
            // {"error": "..."} -- try JSON first, fall back to raw text,
            // never surface a bare status code alone if there's a body to
            // show.
            NSString *message = nil;
            id parsed = data != nil ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if ([parsed isKindOfClass:[NSDictionary class]] && [((NSDictionary *)parsed)[@"error"] isKindOfClass:[NSString class]]) {
                message = ((NSDictionary *)parsed)[@"error"];
            } else if (data.length > 0) {
                message = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            }
            if (message.length == 0) {
                message = [NSString stringWithFormat:@"AI filter request failed with status %ld", (long)status];
            }
            completion(nil, message);
        });
    }];
    [task resume];
}

@end

NS_ASSUME_NONNULL_END
