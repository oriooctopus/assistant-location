#import "GLTabDoubleTap.h"

@implementation GLTabDoubleTap {
    NSTimeInterval _window;
    __weak id _lastTarget;
    NSTimeInterval _lastTime;
}

- (instancetype)initWithWindow:(NSTimeInterval)window {
    self = [super init];
    if (self) {
        _window = window;
    }
    return self;
}

- (BOOL)registerTapOn:(id)target atTime:(NSTimeInterval)time {
    if (target == _lastTarget && time - _lastTime <= _window) {
        _lastTarget = nil;
        return YES;
    }
    _lastTarget = target;
    _lastTime = time;
    return NO;
}

@end
