// The Listen tab: a WKWebView pointing at the Listen web app on the desktop
// box, port 8315. Thin subclass of GLWebModuleViewController (URL + name),
// plus the `listen` script message handler and the native audio objects that
// handler drives. Protocol: PROTOCOL.md in this directory.

#import "GLWebModuleViewController.h"

@interface ListenViewController : GLWebModuleViewController
@end
