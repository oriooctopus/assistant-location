#import "TodosViewController.h"

#import "BakedConfig.h"

// The host is the one build-time secret (GL_BAKED_HOST, from
// App/BakedConfig.h); this tab only owns its own port.
//
// HTTPS on 9308, not HTTP on 8308, and that is load-bearing rather than
// cosmetic: todo-sorter's offline-first shell cache is a ServiceWorker plus
// Cache Storage, and both are hard-gated by the browser to SECURE CONTEXTS.
// Over http://<raw tailnet IP>:8308 `navigator.serviceWorker` is literally
// undefined, so the whole cache silently never registers and every load pays
// the full round-trip cost (measured: ~2s cold on the phone vs 133ms warm
// over HTTPS). 9308 is `tailscale serve --https=9308` proxying to 8308 --
// tailnet-only, deliberately NOT the funnelled :443, which is public
// internet. See ~/.claude/rules/ports.md.
static NSInteger const kTodosPort = 9308;

@implementation TodosViewController

- (instancetype)init {
    NSString *urlString = [NSString stringWithFormat:@"https://%@:%ld/", GL_BAKED_HOST, (long)kTodosPort];
    return [self initWithURL:[NSURL URLWithString:urlString]
                  displayName:@"todo sorter"];
}

@end
