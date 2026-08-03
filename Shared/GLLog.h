// One logging macro prefixing the calling class, so log lines are
// attributable at a glance. Four modules log nothing today, and the
// prefixes that do exist elsewhere are inconsistent ("Module registry: ...",
// no prefix at all, etc.) — GLLog() is the convention going forward.
//
// Usage: GLLog(@"uploaded %@", filename); -> NSLog(@"[EventsViewController] uploaded %@", filename)

#import <Foundation/Foundation.h>

#define GLLog(format, ...) \
    NSLog(@"[%@] " format, NSStringFromClass([self class]), ##__VA_ARGS__)
