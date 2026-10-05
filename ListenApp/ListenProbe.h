// ListenProbe: framework-behaviour probes for CI (CLAUDE.md: "probe framework
// behavior before asserting on it"). Runs only when the UITEST_LISTEN_PROBE
// environment variable is set (sim-test.yml sets it for one dedicated launch).
// Logs facts with the "ListenProbe:" prefix and asserts nothing.
//
// Probes: (1) the web view and user content controller are reachable from the
// subclass via KVC; (2) a page's `listen` postMessage reaches the handler and
// the native reply/event land back in window.__listenReply/__listenEvent;
// (3) AVPlayerItem honours forwardPlaybackEndTime after a seek and posts
// DidPlayToEnd; (4) ListenPlayer's whole step loop against local audio files.

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ListenProbe : NSObject
+ (void)runIfRequestedWithWebView:(WKWebView *)webView;
@end

NS_ASSUME_NONNULL_END
