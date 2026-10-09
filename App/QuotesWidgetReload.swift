// Bridges WidgetKit.WidgetCenter.reloadAllTimelines() (Swift-only -- Apple
// ships no Objective-C header for WidgetKit) so QuotesStore.m's ObjC save call
// sites in the Quotes app can trigger it after every write. ObjC call sites
// #import "Overland-Swift.h" (the Quotes target names its generated header
// that way, see scripts/add_quotes_app.rb) and never this file directly.
//
// Compiled into the Quotes app only, not the QuotesWidget extension (see
// scripts/add_quotes_widget_ext.rb) even though QuotesStore.m is in both: the
// widget extension never writes the store, and WidgetCenter calls from inside
// a widget extension process are wasted work.
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
