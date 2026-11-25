// "Start a Claude Code session from my phone" -- an overflow (More-grid)
// module wrapping session.html (Modules/WebPages/session.html). See
// MODULES.md at the repo root.

#import <Foundation/Foundation.h>
#import "GLModule.h"

@interface SessionsModule : NSObject <GLModule>
/// Opens the Sessions tab on that session's chat (a notify-push tap).
+ (void)openSessionChat:(NSString *)sessionId;
@end
