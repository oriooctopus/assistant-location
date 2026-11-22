#import "AutoJournalLiveTranslator.h"

#import "AutoJournalLiveText.h"
#import "BakedConfig.h"
#import "GLEndpoints.h"

static NSTimeInterval const kDebounceSeconds = 0.7;

@implementation AutoJournalLiveTranslator {
    AutoJournalStaleGuard *_guard;
    NSTimer *_debounce;
    NSString *_lastSent;
}

- (instancetype)init {
    self = [super init];
    if (self) _guard = [[AutoJournalStaleGuard alloc] init];
    return self;
}

- (void)dealloc { [_debounce invalidate]; }

- (void)textDidChange:(NSString *)text {
    [_debounce invalidate];
    _debounce = nil;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) { [self cancel]; return; }
    if ([trimmed isEqualToString:_lastSent]) return;
    NSUInteger token = [_guard begin]; // anything already in flight is now stale
    if (self.onUpdate) self.onUpdate(nil, nil, YES);
    __weak typeof(self) weakSelf = self;
    _debounce = [NSTimer scheduledTimerWithTimeInterval:kDebounceSeconds repeats:NO block:^(NSTimer *t) {
        [weakSelf sendText:trimmed token:token];
    }];
}

- (void)cancel {
    [_debounce invalidate];
    _debounce = nil;
    [_guard invalidate];
    _lastSent = nil;
}

- (void)sendText:(NSString *)text token:(NSUInteger)token {
    _lastSent = text;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:GLEndpointURL(@"/journal/translate")];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 10;
    [request setValue:[NSString stringWithFormat:@"Bearer %@", GL_BAKED_TOKEN] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"text": text} options:0 error:nil];

    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *translated = nil;
        NSString *failure = nil;
        if (error) {
            failure = error.localizedDescription;
        } else {
            NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
            NSDictionary *body = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (status == 200 && [body[@"text"] isKindOfClass:[NSString class]]) {
                translated = body[@"text"];
            } else {
                failure = [NSString stringWithFormat:@"translate HTTP %ld: %@", (long)status,
                           [body[@"error"] isKindOfClass:[NSString class]] ? body[@"error"] : @"unexpected reply"];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            AutoJournalLiveTranslator *s = weakSelf;
            if (!s || ![s->_guard isCurrent:token]) return; // a newer text went out meanwhile
            if (failure) s->_lastSent = nil;               // let the same text be retried on the next change
            if (s.onUpdate) s.onUpdate(translated, failure, NO);
        });
    }] resume];
}

@end
