// The Debate tab: a WKWebView pointing at the Debate web app on the desktop
// box, HTTPS port 9335 (tailscale serve, tailnet-only). Thin subclass of
// GLWebModuleViewController (Shared/); this file supplies only URL + name.

#import "GLWebModuleViewController.h"

@interface DebateViewController : GLWebModuleViewController
@end
