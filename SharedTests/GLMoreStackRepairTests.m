// Regression coverage for the Journal-open crash (2026-10-12): the More
// stack repair must never put the root controller in the stack twice, or
// UIKit raises "All view controllers in a navigation controller must be
// distinct". Plain NSObjects stand in for view controllers -- the function
// only compares identity.
#import <XCTest/XCTest.h>
#import "GLMoreStackRepair.h"

@interface GLMoreStackRepairTests : XCTestCase
@end

@implementation GLMoreStackRepairTests {
    NSObject *_root, *_list, *_journal;
}

- (void)setUp {
    _root = [NSObject new];
    _list = [NSObject new];
    _journal = [NSObject new];
}

- (void)testEmptyStackGetsRoot {
    XCTAssertEqualObjects(GLMoreStackWithRoot(@[], _root), (@[_root]));
}

- (void)testSystemListIsReplacedAndModuleKept {
    XCTAssertEqualObjects(GLMoreStackWithRoot(@[_list, _journal], _root), (@[_root, _journal]));
}

// The shape from the crash reports: UIKit's list inserted under a stack that
// still held root. Overwriting index 0 alone gave [root, root, journal].
- (void)testRootAlreadyAboveSystemListIsNotDuplicated {
    XCTAssertEqualObjects(GLMoreStackWithRoot(@[_list, _root, _journal], _root), (@[_root, _journal]));
    XCTAssertEqualObjects(GLMoreStackWithRoot(@[_list, _root], _root), (@[_root]));
}

- (void)testRootedStackIsLeftAsIs {
    XCTAssertEqualObjects(GLMoreStackWithRoot(@[_root, _journal], _root), (@[_root, _journal]));
}

- (void)testDuplicateRootAboveRootedStackIsDropped {
    XCTAssertEqualObjects(GLMoreStackWithRoot(@[_root, _root, _journal], _root), (@[_root, _journal]));
}

@end
