import UIKit
import WebKit

/// Serves the bundled `Web/` folder (a copy of web/dist) at due-app://app/. A custom scheme rather than file:// because
/// WKWebView refuses module scripts on file URLs.
final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "due-app"
    private let root = Bundle.main.resourceURL!.appendingPathComponent("Web", isDirectory: true)
    private static let mime = ["html": "text/html", "js": "text/javascript", "css": "text/css", "woff2": "font/woff2", "json": "application/json", "svg": "image/svg+xml", "png": "image/png"]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let url = task.request.url!
        var path = url.path
        if path == "" || path == "/" { path = "/index.html" }
        let file = root.appendingPathComponent(String(path.dropFirst()))
        guard file.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path), let data = try? Data(contentsOf: file) else {
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            task.didFinish()
            return
        }
        let type = Self.mime[file.pathExtension] ?? "application/octet-stream"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                        headerFields: ["Content-Type": type, "Content-Length": String(data.count), "Cache-Control": "no-cache"])!)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// `webkit.messageHandlers.due.postMessage({cmd, ...})` from the web layer; the reply resolves the promise.
final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
    var onReady: (() -> Void)?
    var onIntentsApplied: (() -> Void)?

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard let m = message.body as? [String: Any], let cmd = m["cmd"] as? String else { return replyHandler(nil, "malformed message") }
        do {
            switch cmd {
            case "kvGet": replyHandler(try Storage.get(m["key"] as! String) ?? NSNull(), nil)
            case "kvSet": try Storage.set(m["key"] as! String, m["value"] as! String); replyHandler(true, nil)
            case "schedule": Notifications.replace(with: m["nags"] as! [[String: Any]]); replyHandler(true, nil)
            case "notificationActions": Notifications.registerCategories(m["actions"] as! [[String: String]]); replyHandler(true, nil)
            case "haptic": UIImpactFeedbackGenerator(style: .light).impactOccurred(); replyHandler(true, nil)
            case "takeIntents": replyHandler(Intents.all(), nil)
            case "ackIntents": Intents.ack(m["ids"] as! [String]); replyHandler(true, nil)
            case "ready": onReady?(); replyHandler(true, nil)
            case "intentsApplied": onIntentsApplied?(); replyHandler(true, nil)
            default: replyHandler(nil, "unknown cmd \(cmd)")
            }
        } catch { replyHandler(nil, error.localizedDescription) }
    }
}

enum WebFactory {
    static func make(headless: Bool, bridge: Bridge) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(BundleSchemeHandler(), forURLScheme: BundleSchemeHandler.scheme)
        let inject = try! String(data: JSONSerialization.data(withJSONObject: ["server": Baked.server, "token": Baked.token, "headless": headless]), encoding: .utf8)!
        cfg.userContentController.addUserScript(WKUserScript(source: "window.__DUE_NATIVE = \(inject);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "due")
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.load(URLRequest(url: URL(string: "\(BundleSchemeHandler.scheme)://app/")!))
        return web
    }
}

/// Applies pending notification intents when no UI exists (the app was killed, or woken by the action in the background):
/// loads the same web app invisibly in headless mode, which drains intents, syncs, then reports back.
final class HeadlessRunner {
    static var active = false
    private var web: WKWebView?
    private let bridge = Bridge()
    private var finished = false

    func run(timeout: TimeInterval = 20, done: @escaping () -> Void) {
        HeadlessRunner.active = true
        let finish = { [self] in
            guard !finished else { return }
            finished = true
            HeadlessRunner.active = false
            web = nil
            done()
        }
        bridge.onIntentsApplied = { DispatchQueue.main.async(execute: finish) }
        web = WebFactory.make(headless: true, bridge: bridge)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: finish)
    }
}
