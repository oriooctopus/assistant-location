#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Forces WKWebView to raise the software keyboard when a text element is
// focused PROGRAMMATICALLY (via -evaluateJavaScript:completionHandler:)
// rather than by a real touch landing inside the web content.
//
// ## The bug this works around
//
// GLWebModuleViewController's -callWebFunctionIfDefined: (used by every
// module's native->page pushes, e.g. TodosModule's double-tap/long-press
// "Add Todo" -> `window.openAddTodo()`) drives the page purely through
// -evaluateJavaScript:. When that JS calls `input.focus()`, the element
// genuinely becomes `document.activeElement` -- the focus itself works --
// but WKWebView still does not show the keyboard. WebKit's iOS input layer
// keys keyboard visibility off whether ITS OWN event pipeline recognizes the
// focus as user-initiated (a real touch that began gesture recognition
// inside the web content), not off whether some native gesture triggered
// the call one layer up. A tab-bar double-tap or long-press menu item is a
// completely real user gesture, but by the time it reaches the web page as
// `evaluateJavaScript:@"window.openAddTodo()"`, WebKit has no way to see
// that gesture -- it only sees a JS call, which looks identical to (say) an
// analytics script calling .focus() with no user present at all. So it
// treats the focus as programmatic and suppresses the keyboard, exactly as
// designed for that case.
//
// ## Why this needs private API
//
// WKWebView exposes no public flag, delegate callback, or configuration key
// for "treat this focus as user-initiated" -- Apple has never shipped one.
// The only place that bit exists is on WKContentView, the WKWebView-internal
// UIView subclass that owns first-responder/keyboard plumbing, as the
// `userIsInteracting` argument to its private `_elementDidFocus:...` method
// -- WebKit's internal input layer calls this for EVERY focus, real or
// scripted, and its caller decides that argument from its own touch state.
// This file swizzles that one method so the argument is forced to YES
// before the real implementation runs, which is the actual lever that makes
// the keyboard appear.
//
// ## Why this is acceptable here
//
// This is private API, full stop -- no public replacement exists, and Apple
// could rename or remove it in a future iOS with no notice. It is
// acceptable in THIS app specifically because Overland is built ad-hoc and
// delivered over-the-air to a single user (Oliver) -- it is never submitted
// to the App Store, so there is no App Review private-API scan to fail and
// no other user's build to break. The failure mode of a bad guess is also
// bounded: +install (see GLWebKeyboardFocus.m) checks both known method
// shapes at runtime and, if neither exists, logs loudly and does nothing --
// the keyboard silently fails to appear again (today's bug, not a new one),
// never a crash.
@interface GLWebKeyboardFocus : NSObject

// Installs the swizzle described above, AND suppresses the keyboard's input
// accessory bar (the system prev/next/Done strip). That bar is not counted by
// window.visualViewport, so a web sheet lifted by the keyboard's measured
// height still ends up with its bottom ~55pt covered by it, and no web API
// exposes the bar's height for the page to compensate -- see
// GLSwizzledInputAccessoryView in the .m for the full reasoning.
//
// Idempotent -- safe to call from every GLWebModuleViewController instance
// (there is more than one WKWebView in this app); only the first call does
// anything, the rest are no-ops.
+ (void)install;

// YES iff WKContentView's -inputAccessoryView currently resolves to this
// class's override, i.e. the accessory-bar suppression is actually wired up.
//
// Exposed for testing. It answers "is the override installed", NOT "is the bar
// gone from the screen" -- see GLWebKeyboardFocusTests for why the stronger,
// behavioral form is not available: WKWebView cannot run web content at all in
// a host-less XCTest logic bundle, so no test there can focus a real field.
+ (BOOL)isAccessoryViewSuppressionInstalled;

@end

NS_ASSUME_NONNULL_END
