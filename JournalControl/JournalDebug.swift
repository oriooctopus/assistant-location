// TEMPORARY — server-side debug logging from inside the WIDGET EXTENSION,
// the ground truth for whether a Control press even reaches our perform().
// Mirrors AutoJournalViewController's journalDebugLog: (app side), but this
// runs in the extension process, which the app's instrumentation can't see.
// Delete together with the /debug-log endpoint once the Control chain works.
//
// The host below is a placeholder: the repo is public and the tailnet host
// never lands in git. CI (ota.yml's bake step) seds it to the real DROP_HOST
// before building, same mechanism as App/BakedConfig.h. The guard makes a
// non-baked build silently no-op instead of hammering a bogus hostname.

import Foundation

private let journalDebugHost = "NO_HOST_BAKED_IN"

// Awaited (not fire-and-forget): a Control's perform() is the extension's
// entire lifetime — a detached task would be killed before the request
// leaves the device. The 3s timeout keeps a dead server from making the
// button feel stuck.
func journalDebugLog(_ message: String) async {
    // Deliberately not comparing against the full sentinel: CI's sed targets
    // the `private let` line above by its exact text, and the post-bake grep
    // guard would false-positive on the sentinel appearing here.
    guard !journalDebugHost.hasSuffix("BAKED_IN") else { return }
    var comps = URLComponents()
    comps.scheme = "http"
    comps.host = journalDebugHost
    comps.port = 8302
    comps.path = "/debug-log"
    // The process name settles WHERE an intent's perform() actually ran —
    // "Overland" (app) vs "JournalControl" (extension) — which is the open
    // question behind the whole Control failure. Appended centrally so every
    // call site carries it.
    let proc = ProcessInfo.processInfo.processName
    comps.queryItems = [URLQueryItem(name: "msg", value: "\(message) [proc=\(proc)]")]
    guard let url = comps.url else { return }
    var req = URLRequest(url: url)
    req.timeoutInterval = 3
    _ = try? await URLSession.shared.data(for: req)
}
