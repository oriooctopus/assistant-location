// Bridges WidgetCenter.reloadAllTimelines() (Swift-only, WidgetKit ships no Objective-C header) so
// ListsStateStore.m can trigger it after every state write. Same shape as App/QuotesWidgetReload.swift.
// Compiled into the Lists app only; the widget extension never writes the state.
import WidgetKit

// `public` is load-bearing: this target has no bridging header, and Swift only writes
// internal @objc declarations into the generated "Lists-Swift.h" for targets that have one.
// Without it the ObjC caller fails with "use of undeclared identifier" (the same trap
// ota-quotes run 37791268238 hit for GLQuotesWidgetReload).
@objc public final class GLListsWidgetReload: NSObject {
    @objc public static func reloadAllTimelines() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
