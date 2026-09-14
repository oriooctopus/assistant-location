// Pure selection logic the widget extension (Stage 2) will mirror when it
// picks a quote to show with no native code available to it. Kept entirely
// free of QuotesStore/NSDate.now/NSCalendar.currentCalendar so it can be
// unit-tested deterministically and ported to Swift/JS later without
// dragging any iOS runtime state along.

#import <Foundation/Foundation.h>

#import "QuotesModels.h"

NS_ASSUME_NONNULL_BEGIN

@interface QuotesSelection : NSObject
/// The rule that matched, or nil if none did (see QuotesRuleEngine's doc
/// comment on the no-match fallback).
@property(nonatomic, strong, readonly, nullable) GLQuoteRule *matchedRule;
/// The pool a display should rotate through: for a matched filter rule,
/// quotes matching any listed author OR genre (or, when the rule lists
/// neither, every quote -- an unrestricted filter rule is a deliberate
/// "show anything in this window" state, not a rule that can never match);
/// for a matched AI rule, quotes whose id is in the rule's quoteIds (empty
/// until Stage 2's server resolves the prompt); for no match, every quote.
@property(nonatomic, copy, readonly) NSArray<GLQuote *> *pool;
/// The matched rule's own rotateMinutes, or defaultRotateMinutes when there
/// was no match.
@property(nonatomic, assign, readonly) NSInteger rotateMinutes;
/// YES only for a matched AI-kind rule whose quoteIds is still empty --
/// the "AI resolution coming" state callers should render distinctly from
/// a filter rule that legitimately matched zero quotes.
@property(nonatomic, assign, readonly) BOOL awaitingAIResolution;

- (instancetype)initWithMatchedRule:(nullable GLQuoteRule *)matchedRule
                                pool:(NSArray<GLQuote *> *)pool
                       rotateMinutes:(NSInteger)rotateMinutes
                awaitingAIResolution:(BOOL)awaitingAIResolution NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface QuotesRuleEngine : NSObject

/// The first rule in `rules` (list order, not sorted) whose day+minute
/// window contains `weekday`/`minuteOfDay` wins -- see
/// GLQuoteRule's -containsWeekday:minuteOfDay: for the window/wrap math.
/// No matching rule -> a selection with pool == every quote in `quotes` and
/// rotateMinutes == defaultRotateMinutes (the brief's explicit fallback).
///
/// `weekday` is 1-7, 1 = Sunday -- NSCalendar's own Gregorian convention,
/// so a caller can pass `[calendar component:NSCalendarUnitWeekday
/// fromDate:date]` straight through with no translation.
+ (QuotesSelection *)selectionForWeekday:(NSInteger)weekday
                              minuteOfDay:(NSInteger)minuteOfDay
                                    rules:(NSArray<GLQuoteRule *> *)rules
                                   quotes:(NSArray<GLQuote *> *)quotes
                     defaultRotateMinutes:(NSInteger)defaultRotateMinutes;

/// The single quote a display should show right now: a deterministic,
/// rotateMinutes-bucketed pick from `selection.pool` (bucket = floor(epoch
/// minutes / rotateMinutes), index = bucket % pool.count) so every reader --
/// this app and, in Stage 2, the widget -- lands on the SAME quote for the
/// same wall-clock minute without any shared mutable "current index" state.
/// Returns nil for an empty pool (no quotes matched, or an unresolved AI
/// rule) -- callers render that as "AI resolution coming" /
/// "no quotes match", never as a crash or a silently wrong quote.
+ (nullable GLQuote *)currentQuoteForSelection:(QuotesSelection *)selection
                                    epochMinute:(int64_t)epochMinute;

/// Every instant between `start` and `end` (exclusive of `start`, inclusive
/// of `end`) at which the quote a display shows COULD change -- the
/// widget's (Stage 2) timeline entries need exactly these dates, no more
/// (a naive fixed-interval timeline would either miss a rule boundary or
/// waste entries on minutes nothing actually changes at) and no fewer.
/// Two kinds of instant, computed together in one pass so their relative
/// ordering is exact even when they coincide:
///
/// - A rotation boundary: `epochMinute % rotateMinutes == 0` for whichever
///   selection (rule or default) is active at that minute. epochMinute is
///   absolute (UTC epoch minutes, same as -currentQuoteForSelection:'s
///   parameter) so the rotation cadence is wall-clock-independent -- a
///   60-minute rotation ticks every 60 real minutes regardless of DST,
///   exactly like -currentQuoteForSelection: already behaves.
/// - A rule window boundary: the exact minute a different rule (or no
///   rule) starts matching, per -selectionForWeekday:minuteOfDay:... and
///   GLQuoteRule's -containsWeekday:minuteOfDay: (which is evaluated in
///   `calendar`'s local wall-clock time, so this is where DST and
///   midnight-wrap correctness actually get exercised).
///
/// `calendar` is passed in (not NSCalendar.currentCalendar) so a test can
/// pin a specific timeZone/DST transition deterministically; the widget
/// passes the device's calendar so entries land on ITS wall clock.
+ (NSArray<NSDate *> *)changeDatesFromDate:(NSDate *)start
                                     toDate:(NSDate *)end
                                      rules:(NSArray<GLQuoteRule *> *)rules
                                     quotes:(NSArray<GLQuote *> *)quotes
                       defaultRotateMinutes:(NSInteger)defaultRotateMinutes
                                   calendar:(NSCalendar *)calendar;

@end

NS_ASSUME_NONNULL_END
