// Cold-launch-with-no-connection support for the web tabs (every
// GLWebModuleViewController tab, and the separate Listen app).
//
// Each web app serves a small `<tabBase>/shell.html`: the page with no server
// round trip needed to render. After a successful live load this saves that
// file (GLOfflineShellCache). When a later cold load cannot reach the server
// (a network-class failure, or no response within a short deadline) and a
// saved copy exists, GLOfflineShellLoader shows it with
// -loadSimulatedRequest:responseHTMLString: using the SAME request URL as the live
// page. That keeps the web origin, so the page's own localStorage (its
// offline write queue and read cache) is shared with the live page and the
// saved shell keeps working offline. No service workers: WKWebView only runs
// those for app-bound domains, which these apps are not.
//
// While the saved copy is up a small native "Offline copy" pill shows. The
// page is never swapped for the live one mid-session (that would interrupt
// typing); it goes live on the next cold launch, on the host's Refresh
// control (which calls -loadLiveRequest: again), or when the app returns to
// the foreground after the copy has been up a while and the server answers
// (-swapToLiveIfReachable).

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, GLOfflineShellRefreshResult) {
    /// 200 + text/html: saved.
    GLOfflineShellRefreshUpdated,
    /// The server answered but not with a usable shell (404 when that app has
    /// no shell yet, wrong content type, ...). Any old copy is kept.
    GLOfflineShellRefreshUnavailable,
    /// Transport error: the server could not be reached.
    GLOfflineShellRefreshUnreachable,
};

/// Saved shells on disk, keyed by the page's scheme/host/port/path (query
/// ignored, so ?theme=dark and ?theme=light share one entry).
@interface GLOfflineShellCache : NSObject

/// Application Support/ShellCache.
+ (instancetype)sharedCache;

- (instancetype)initWithDirectory:(NSURL *)directory NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// `<pageURL resolved against "shell.html">`, e.g. http://h:8312/ -> http://h:8312/shell.html.
+ (NSURL *)shellURLForPageURL:(NSURL *)pageURL;
+ (NSString *)cacheKeyForPageURL:(NSURL *)pageURL;

- (nullable NSString *)cachedHTMLForPageURL:(NSURL *)pageURL;
/// The sidecar's fetchedAt, nil when nothing is saved.
- (nullable NSDate *)fetchedAtForPageURL:(NSURL *)pageURL;

/// Atomically saves `data` (must be UTF-8) and its JSON sidecar.
- (BOOL)storeShellData:(NSData *)data forPageURL:(NSURL *)pageURL error:(NSError **)error;

/// Fetches the shell in the background and saves it. `completion` runs on the
/// main queue.
- (void)refreshShellForPageURL:(NSURL *)pageURL
                       session:(NSURLSession *)session
                    completion:(void (^)(GLOfflineShellRefreshResult result))completion;
@end

@class GLOfflineShellLoader;

@protocol GLOfflineShellLoaderDelegate <NSObject>
/// The saved shell is (or, on a refresh while it is already up, stays) on
/// screen. Stop spinners and hide any error view.
- (void)offlineShellLoaderDidShowShell:(GLOfflineShellLoader *)loader;
/// The live load failed and there is no saved shell to fall back to (or the
/// failure was not a network-class one).
- (void)offlineShellLoader:(GLOfflineShellLoader *)loader didFailLiveLoad:(NSError *)error;
@end

/// Owns the load of one tab's remote page and its fallback to the saved shell.
/// The host stays the web view's WKNavigationDelegate and forwards the four
/// navigation callbacks below.
@interface GLOfflineShellLoader : NSObject

@property(nonatomic, weak, nullable) id<GLOfflineShellLoaderDelegate> delegate;
/// Seconds to wait for the live response before showing a saved shell.
/// Default 4 (a guess: long enough that a slow tailnet hop on cellular still
/// wins, short enough that an offline cold launch does not look hung).
@property(nonatomic) NSTimeInterval deadline;
/// How long the shell must have been up before -swapToLiveIfReachable acts.
/// Default 60.
@property(nonatomic) NSTimeInterval minShellSecondsBeforeAutoSwap;
@property(nonatomic, readonly) BOOL showingShell;
/// The "Offline copy" pill, added to the host view. Hidden unless the shell is up.
@property(nonatomic, strong, readonly) UIView *indicatorView;

- (instancetype)initWithWebView:(WKWebView *)webView
                       hostView:(UIView *)hostView
                          cache:(GLOfflineShellCache *)cache
                        session:(NSURLSession *)session NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Starts the live load (used for the first load and for every Refresh).
- (void)loadLiveRequest:(NSURLRequest *)request;

/// If the shell has been up for minShellSecondsBeforeAutoSwap and the server
/// answers a shell fetch, loads the live page. Call on app foreground.
- (void)swapToLiveIfReachable;

// Forward from the host's WKNavigationDelegate. Only navigations started via
// -loadLiveRequest: (and the shell's own) are tracked; others are ignored.
- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation;
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation;
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation;
/// Returns YES when the loader consumed the failure (the host must then do
/// nothing); NO when it was not a navigation this loader started.
- (BOOL)webView:(WKWebView *)webView
    didFailProvisionalNavigation:(WKNavigation *)navigation
                       withError:(NSError *)error;

@end

NS_ASSUME_NONNULL_END
