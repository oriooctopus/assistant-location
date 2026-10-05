// ListenRewind: pure-Foundation rules for Listen "rewind presets"
// (settings.rewinds in PROTOCOL.md). Kept free of AVFoundation/UIKit so the
// host-less SharedTests bundle can compile it. Mirrors listen/public/engine.js.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ListenRewind : NSObject

/// Max presets in settings.rewinds.
+ (NSInteger)maxPresets;
/// [{steps:[translation, original], slow:0}], used when settings.rewinds is absent.
+ (NSArray<NSDictionary *> *)defaultPresets;
/// settings.rewinds, or the default when absent.
+ (NSArray<NSDictionary *> *)presetsInSettings:(NSDictionary *)settings;
/// nil when `value` is a valid rewinds array (1...4 presets), else an error message.
+ (nullable NSString *)validatePresets:(nullable id)value;
/// nil when `steps`/`slow` are a valid rewind (non-empty known kinds, slow int 0...50), else an error message.
+ (nullable NSString *)validateSteps:(nullable id)steps slow:(nullable id)slow;
/// `steps` minus `vocab` when the section has no vocab clip, order kept.
+ (NSArray<NSString *> *)playableKindsForSteps:(NSArray<NSString *> *)steps hasVocab:(BOOL)hasVocab;
/// "English → Original", "Original 20% slower", "English → Original (original 20% slower)".
+ (NSString *)nameForSteps:(NSArray<NSString *> *)steps slow:(NSInteger)slow;

@end

NS_ASSUME_NONNULL_END
