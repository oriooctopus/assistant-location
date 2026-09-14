// Lets QuotesWidget.swift (Swift) call into the ObjC Quotes classes this
// target now also compiles (see scripts/add_quotes_to_journalcontrol.rb):
// QuotesStore.h/QuotesModels.h for the data model + selection engine, and
// this target's own QuotesWidgetLoader.h for the @try/@catch wrapper around
// QuotesStore that keeps a genuine keychain exception from crashing the
// whole widget extension process (see that header's own comment for why
// Swift needs this rather than catching QuotesStore directly).
//
// Per-target, not shared with App/Overland-Bridging-Header.h -- a bridging
// header is a build setting on ONE target (SWIFT_OBJC_BRIDGING_HEADER),
// and JournalControl is a separate target from the app.
#import "QuotesModels.h"
#import "QuotesRuleEngine.h"
#import "QuotesStore.h"
#import "QuotesWidgetLoader.h"
