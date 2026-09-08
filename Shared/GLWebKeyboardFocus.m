#import "GLWebKeyboardFocus.h"

#import <objc/runtime.h>
#import <WebKit/WebKit.h>

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

// Returns nil so WKWebView renders no input accessory bar above the keyboard.
//
// iOS puts a system bar (previous/next chevrons + Done) between the keyboard
// and the page whenever a form field is focused. It is NOT part of the
// keyboard as far as window.visualViewport is concerned: visualViewport.height
// shrinks by the keyboard alone, so a web sheet lifted by exactly that much
// still has this bar floating on top of its bottom ~55pt -- which is where the
// add-todo composer's list chip and Save button live (Oliver, 2026-09-07:
// "its still covering some of it"). No web API reports this bar's height, so
// the page cannot compensate for it; removing it is the only fix available.
//
// It is also unwanted on its own merits here: every text input in this app is
// a single field, so the prev/next chevrons navigate nothing, and the bar's
// Done checkmark sits directly above the composer's own Save button offering a
// second, differently-behaved confirm.
static id GLSwizzledInputAccessoryView(id self, SEL _cmd) {
    return nil;
}

@implementation GLWebKeyboardFocus

+ (void)install {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Force WebKit's image to load BEFORE either swizzle looks for
        // WKContentView. dyld loads a linked framework lazily, on first use,
        // and until that happens none of its Objective-C classes -- private
        // ones included -- are registered, so NSClassFromString(@"WKContentView")
        // returns nil and both installs below silently do nothing. Touching
        // WKWebView is that first use.
        //
        // This is not hypothetical: GLWebModuleViewController calls +install in
        // -viewDidLoad, several lines BEFORE it creates its WKWebView, so on a
        // launch where no web view existed yet the whole class was a no-op. It
        // has been working only because something else in the app happened to
        // touch WebKit first. Proven on CI (run 34182864150), where a test that
        // called +install with no WKWebView anywhere found WKContentView nil.
        (void)[WKWebView class];

        [self installSwizzle];
        // MUTATION: suppression disabled to prove the test catches it
    });
}

// Suppresses the input accessory bar described above GLSwizzledInputAccessoryView.
//
// class_addMethod FIRST, deliberately: -inputAccessoryView is declared on
// UIResponder, so WKContentView may well not implement it itself. Calling
// method_setImplementation on the Method that class_getInstanceMethod returns
// in that case would rewrite UIRESPONDER's implementation -- every responder in
// the app, native views included, would lose its accessory view. Adding the
// method directly to WKContentView instead confines the override to that one
// class; class_addMethod returns NO only when WKContentView really does define
// its own, which is the one case where overwriting its implementation is both
// safe and what we want.
+ (void)installAccessoryViewSuppression {
    Class contentViewClass = NSClassFromString(@"WKContentView");
    if (!contentViewClass) return; // already logged loudly by installSwizzle above

    SEL selector = NSSelectorFromString(@"inputAccessoryView");
    // "@@:" -- returns an object, takes the implicit self + _cmd and nothing else.
    if (class_addMethod(contentViewClass, selector, (IMP)GLSwizzledInputAccessoryView, "@@:")) {
        NSLog(@"GLWebKeyboardFocus: input accessory bar suppressed (added -inputAccessoryView to WKContentView).");
        return;
    }

    Method existing = class_getInstanceMethod(contentViewClass, selector);
    if (!existing) {
        NSLog(@"GLWebKeyboardFocus: could neither add nor find -inputAccessoryView on WKContentView -- "
              @"the keyboard's accessory bar will still cover the bottom of any web sheet.");
        return;
    }
    method_setImplementation(existing, (IMP)GLSwizzledInputAccessoryView);
    NSLog(@"GLWebKeyboardFocus: input accessory bar suppressed (replaced WKContentView's own -inputAccessoryView).");
}

+ (BOOL)isAccessoryViewSuppressionInstalled {
    Class contentViewClass = NSClassFromString(@"WKContentView");
    if (!contentViewClass) return NO;
    IMP current = class_getMethodImplementation(contentViewClass, NSSelectorFromString(@"inputAccessoryView"));
    return current == (IMP)GLSwizzledInputAccessoryView;
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
