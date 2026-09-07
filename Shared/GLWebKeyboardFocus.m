#import "GLWebKeyboardFocus.h"

#import <objc/runtime.h>

// The original WKContentView implementation, captured once at install time.
// Both known method shapes (see +install) share an identical C signature --
// (id, SEL, id, BOOL, BOOL, BOOL, id) -- so one function-pointer type and one
// swizzled implementation cover either shape; only the SELECTOR differs
// between iOS versions, never the argument types.
typedef void (*GLElementDidFocusIMP)(id, SEL, id, BOOL, BOOL, BOOL, id);
static GLElementDidFocusIMP GLOriginalElementDidFocusIMP;

// Replaces the real `userIsInteracting` argument with YES, unconditionally,
// then runs the original implementation with everything else untouched. This
// is the entire fix: WebKit's own input layer decides keyboard visibility
// from this argument, and every other parameter (the focused element, the
// blur/activity-state flags, the user object) must reach the original
// implementation exactly as WebKit sent them.
static void GLSwizzledElementDidFocus(id self, SEL _cmd, id element,
                                       BOOL userIsInteracting,
                                       BOOL blurPreviousNode,
                                       BOOL activityStateChangesOrChangingActivityState,
                                       id userObject) {
    GLOriginalElementDidFocusIMP(self, _cmd, element, YES, blurPreviousNode,
                                  activityStateChangesOrChangingActivityState, userObject);
}

@implementation GLWebKeyboardFocus

+ (void)install {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [self installSwizzle];
    });
}

+ (void)installSwizzle {
    Class contentViewClass = NSClassFromString(@"WKContentView");
    if (!contentViewClass) {
        NSLog(@"GLWebKeyboardFocus: WKContentView not found -- WebKit's private view class may have "
              @"been renamed. Programmatic focus (e.g. TodosModule's double-tap Add-Todo) will NOT "
              @"raise the keyboard until this is updated.");
        return;
    }

    // iOS has shipped two different argument-label shapes for this method
    // over its lifetime; try the newer one first, then fall back. The
    // underlying argument TYPES are identical either way (see the typedef
    // above), so whichever shape matches, the same swizzled IMP works.
    SEL activityStateChangesSelector =
        NSSelectorFromString(@"_elementDidFocus:userIsInteracting:blurPreviousNode:activityStateChanges:userObject:");
    SEL changingActivityStateSelector =
        NSSelectorFromString(@"_elementDidFocus:userIsInteracting:blurPreviousNode:changingActivityState:userObject:");

    Method method = class_getInstanceMethod(contentViewClass, activityStateChangesSelector);
    SEL matchedSelector = method ? activityStateChangesSelector : nil;
    if (!method) {
        method = class_getInstanceMethod(contentViewClass, changingActivityStateSelector);
        matchedSelector = method ? changingActivityStateSelector : nil;
    }

    if (!method) {
        NSLog(@"GLWebKeyboardFocus: neither known _elementDidFocus:... selector shape exists on "
              @"WKContentView on this iOS version -- WebKit renamed its private focus entry point "
              @"again. Programmatic focus (e.g. TodosModule's double-tap Add-Todo) will NOT raise "
              @"the keyboard until this is updated with the new selector.");
        return;
    }

    GLOriginalElementDidFocusIMP = (GLElementDidFocusIMP)method_getImplementation(method);
    method_setImplementation(method, (IMP)GLSwizzledElementDidFocus);

    NSLog(@"GLWebKeyboardFocus: installed on WKContentView -- matched selector \"%@\" (%@ shape). "
          @"Programmatic focus will now raise the keyboard.",
          NSStringFromSelector(matchedSelector),
          matchedSelector == activityStateChangesSelector ? @"activityStateChanges" : @"changingActivityState");
}

@end
