#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Debounced English -> pt-BR translation of the live transcript's tail, via POST /journal/translate.
// Preview only: no queue, no retry; the newest request wins and older replies are dropped.
@interface AutoJournalLiveTranslator : NSObject

// Main queue. loading is YES from the moment a request is scheduled until its reply arrives.
// Exactly one of translated / error is non-nil on a finished request; both nil while loading.
@property(nonatomic, copy, nullable) void (^onUpdate)(NSString *_Nullable translated, NSString *_Nullable error, BOOL loading);

// The text to translate changed; sends after ~700 ms of quiet.
- (void)textDidChange:(NSString *)text;
// Drops anything scheduled or in flight.
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
