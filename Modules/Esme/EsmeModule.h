// Esme micro app. See MODULES.md at the repo root.
//
// A private, daily relationship check-in journal (Oliver's own use, tracking
// how he feels day to day). Thin web wrapper like Finances -- see
// EsmeViewController.m -- plus a native daily local-notification reminder
// (this file) that deep-links back into the web app's check-in flow.

#import <Foundation/Foundation.h>
#import "GLModule.h"

@interface EsmeModule : NSObject <GLModule>
@end
