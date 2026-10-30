// Pure Foundation parser for what was said into the Clips player's mic button
// (compiled into SharedTests too): a note, or a new or renamed section, plus
// where it goes: a spoken time, a named section, or the playhead.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ClipsVoiceCommand : NSObject

/// nil when the transcript holds nothing to save. Otherwise one of:
///   {kind: "note", text, time, timeIgnored}
///   {kind: "section", name, start, end, timeIgnored, optional truncateID}: add it,
///     first ending section truncateID at `start`
///   {kind: "rename", name, sectionID, start, timeIgnored}
/// timeIgnored is YES when the spoken time was past the end, so the playhead was used.
/// `sections` are {id, name, start, end}, ordered by start. `duration` is 0 when unknown.
+ (nullable NSDictionary *)commandFromTranscript:(NSString *)transcript
                                        sections:(NSArray<NSDictionary *> *)sections
                                        playhead:(NSTimeInterval)playhead
                                        duration:(NSTimeInterval)duration;

/// Seconds for a spoken time ("1:23", "83 seconds", "one minute twenty", "one twenty"), or -1.
+ (NSTimeInterval)secondsFromPhrase:(NSString *)phrase;

@end

NS_ASSUME_NONNULL_END
