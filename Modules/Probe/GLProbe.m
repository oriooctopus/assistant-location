// Throwaway probe: proves a file inside the synchronized Modules/ folder is
// compiled into the app with no project.pbxproj entry of its own.
#import <Foundation/Foundation.h>

@interface GLProbe : NSObject
@end

@implementation GLProbe
+ (void)load {
    NSLog(@"GLProbe: synchronized folder compiled this file");
}
@end
