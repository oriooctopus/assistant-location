// Bridges QuotesStore into Swift for QuotesWidget.swift. QuotesStore raises
// plain NSException on a genuine keychain failure (not the
// errSecMissingEntitlement degrade, which QuotesStore.m already handles
// gracefully -- see its class doc) -- Swift has no way to catch an ObjC
// exception, so a raise inside a Swift TimelineProvider would crash the
// whole widget extension process, leaving the OS to show a blank tile with
// no indication why. This file is the ONE place that @try/@catches
// QuotesStore, so every other caller in this target can treat "couldn't
// read the store" as an ordinary value (QuotesWidgetSnapshot.unavailableMessage)
// instead of a control-flow hazard.

#import <Foundation/Foundation.h>

#import "QuotesModels.h"

NS_ASSUME_NONNULL_BEGIN

@interface QuotesWidgetSnapshot : NSObject

@property(nonatomic, copy, readonly) NSArray<GLQuote *> *quotes;
@property(nonatomic, copy, readonly) NSArray<GLQuoteRule *> *rules;
@property(nonatomic, assign, readonly) NSInteger defaultRotateMinutes;

/// Non-nil whenever the store could not be fully read -- either
/// QuotesStore's own errSecMissingEntitlement degrade (see
/// QuotesStore.h's `unavailableError`) or a caught NSException from a
/// genuine keychain/JSON failure. `quotes` still reflects whatever this
/// class could recover (stock quotes, at minimum -- see
/// +loadSnapshot's doc) even when this is set; `rules` may be empty.
@property(nonatomic, copy, readonly, nullable) NSString *unavailableMessage;

- (instancetype)initWithQuotes:(NSArray<GLQuote *> *)quotes
                          rules:(NSArray<GLQuoteRule *> *)rules
           defaultRotateMinutes:(NSInteger)defaultRotateMinutes
             unavailableMessage:(nullable NSString *)unavailableMessage NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface QuotesWidgetLoader : NSObject

/// Always returns a snapshot, never throws or raises across this call --
/// see the file header above for why that guarantee matters here
/// specifically. A missing keychain item (fresh install, no rules/imports
/// saved yet) and a missing keychain entitlement (unsigned build, or a
/// provisioning mismatch) both produce stock-quotes-only, matching
/// QuotesViewController's own "normal empty state, no rules" behavior for
/// the same two conditions.
+ (QuotesWidgetSnapshot *)loadSnapshot;

@end

NS_ASSUME_NONNULL_END
