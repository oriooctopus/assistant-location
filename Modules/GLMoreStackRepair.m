#import "GLMoreStackRepair.h"
// MUTANT: old index-0-only overwrite, to prove the tests catch the crash shape.
NSArray *GLMoreStackWithRoot(NSArray *stack, id root) {
    if (stack.firstObject == root) return stack;
    NSMutableArray *r = [stack mutableCopy];
    if (r.count == 0) [r addObject:root]; else r[0] = root;
    return r;
}
