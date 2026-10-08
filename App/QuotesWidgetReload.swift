// Bridges WidgetKit.WidgetCenter.reloadAllTimelines() (Swift-only -- Apple
// ships no Objective-C header for WidgetKit, the same way SwiftUI has none)
// so QuotesStore.m's ObjC save call sites can trigger it after every write.
// The App target is otherwise 100% Objective-C today -- this is
// deliberately the ONLY .swift file in it, existing purely to make Xcode
// auto-generate "Overland-Swift.h" (it does this automatically for any
// @objc-visible Swift symbol once a target has >=1 .swift file and
// SWIFT_VERSION set -- both already true here, see project.pbxproj's App
// target build settings, from a time before this file existed). ObjC call
// sites #import "Overland-Swift.h" and never this file directly.
//
// Deliberately kept OUT of the JournalControl target (see
// scripts/add_quotes_to_journalcontrol.rb) even though QuotesStore.m is
// compiled into both: the widget extension has nothing to reload when ITS
// OWN save completes (widgets don't write to this store; only the app's
// Quotes tab does), and WidgetCenter calls from inside a widget extension
// process are meaningless/wasted work at best.
import WidgetKit

// `public` is load-bearing: the standalone Quotes target has no bridging
// header, and Swift only writes internal @objc declarations into the generated
// "Overland-Swift.h" for targets that have one (the Overland app does). Without
// it the header has no GLQuotesWidgetReload and the ObjC callers fail with
// "use of undeclared identifier" (ota-quotes run 37791268238).
@objc public final class GLQuotesWidgetReload: NSObject {
    @objc public static func reloadAllTimelines() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
