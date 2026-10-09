#import "QuotesWidgetLoader.h"

#import "QuotesStore.h"

NS_ASSUME_NONNULL_BEGIN

@implementation QuotesWidgetSnapshot

- (instancetype)initWithQuotes:(NSArray<GLQuote *> *)quotes
                          rules:(NSArray<GLQuoteRule *> *)rules
           defaultRotateMinutes:(NSInteger)defaultRotateMinutes
             unavailableMessage:(nullable NSString *)unavailableMessage {
    self = [super init];
    if (self) {
        _quotes = [quotes copy];
        _rules = [rules copy];
        _defaultRotateMinutes = defaultRotateMinutes;
        _unavailableMessage = [unavailableMessage copy];
    }
    return self;
}

@end

@implementation QuotesWidgetLoader

+ (QuotesWidgetSnapshot *)loadSnapshot {
    QuotesStore *store = [QuotesStore sharedStore];
    NSArray<GLQuote *> *quotes = @[];
    NSArray<GLQuoteRule *> *rules = @[];
    NSInteger defaultRotate = 60;
    NSString *unavailable = nil;

    @try {
        // Each of these re-reads the keychain document independently (see
        // QuotesStore.m's -documentOrEmpty) -- errSecMissingEntitlement is
        // already handled inside QuotesStore (returns the empty document,
        // sets unavailableError), so getting here without raising is the
        // COMMON case for an unsigned/no-provisioning-match build, not an
        // edge case.
        quotes = [store allQuotes];
        rules = [store rules];
        defaultRotate = [store defaultRotateMinutes];
        unavailable = store.unavailableError.localizedDescription;
    } @catch (NSException *exception) {
        // A genuine keychain failure (corrupt JSON, an OSStatus other than
        // errSecMissingEntitlement) still raises by QuotesStore's design --
        // see its class doc for why that's deliberate (a raise that looks
        // identical to "fresh install" could hide a real write that never
        // landed). `-allQuotes` raised before merging anything in, so
        // `quotes` above is still `@[]`; fall back to stockQuotes directly
        // (loaded once at QuotesStore init, straight from the app bundle,
        // no keychain touch at all) rather than leave the widget with
        // NOTHING to show.
        quotes = store.stockQuotes;
        rules = @[];
        defaultRotate = 60;
        unavailable = [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @"(no reason)"];
    }

    return [[QuotesWidgetSnapshot alloc] initWithQuotes:quotes
                                                    rules:rules
                                     defaultRotateMinutes:defaultRotate
                                       unavailableMessage:unavailable];
}

@end

NS_ASSUME_NONNULL_END
