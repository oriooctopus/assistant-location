#import "GLMoreStackRepair.h"

NSArray *GLMoreStackWithRoot(NSArray *stack, id root) {
    // Index 0 is either root already or UIKit's own More list; either way it
    // becomes root. Everything above it is kept, minus any copy of root.
    NSMutableArray *rest = stack.count > 1
        ? [[stack subarrayWithRange:NSMakeRange(1, stack.count - 1)] mutableCopy]
        : [NSMutableArray array];
    [rest removeObjectIdenticalTo:root];
    return [@[root] arrayByAddingObjectsFromArray:rest];
}
