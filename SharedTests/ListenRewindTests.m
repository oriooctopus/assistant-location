// Pure-logic tests for ListenRewind: preset validation, vocab skipping and the
// derived preset name (must match rewindName in listen/public/engine.js).
#import <XCTest/XCTest.h>
#import "ListenRewind.h"

@interface ListenRewindTests : XCTestCase
@end

@implementation ListenRewindTests

- (void)testAbsentRewindsFallBackToTranslationThenOriginal {
    NSArray *presets = [ListenRewind presetsInSettings:@{}];
    XCTAssertEqual(presets.count, 1u);
    XCTAssertEqualObjects(presets[0][@"steps"], (@[@"translation", @"original"]));
    XCTAssertEqualObjects(presets[0][@"slow"], @0);
}

- (void)testPresetsInSettingsReturnsConfiguredList {
    NSArray *rewinds = @[@{@"steps": @[@"original"], @"slow": @20}];
    XCTAssertEqualObjects([ListenRewind presetsInSettings:@{@"rewinds": rewinds}], rewinds);
}

- (void)testValidPresetsPass {
    NSArray *ok = @[@{@"steps": @[@"vocab", @"clear", @"translation", @"original"], @"slow": @50},
                    @{@"steps": @[@"original"], @"slow": @0}];
    XCTAssertNil([ListenRewind validatePresets:ok]);
}

- (void)testInvalidPresetsAreRejected {
    NSDictionary *good = @{@"steps": @[@"original"], @"slow": @0};
    XCTAssertNotNil([ListenRewind validatePresets:@[]], @"empty list");
    XCTAssertNotNil([ListenRewind validatePresets:(@[good, good, good, good, good])], @"more than 4");
    XCTAssertNotNil([ListenRewind validatePresets:@[@{@"steps": @[], @"slow": @0}]], @"empty steps");
    XCTAssertNotNil([ListenRewind validatePresets:@[@{@"steps": @[@"bogus"], @"slow": @0}]], @"unknown kind");
    XCTAssertNotNil([ListenRewind validatePresets:@[@{@"steps": @[@"original"], @"slow": @51}]], @"slow > 50");
    XCTAssertNotNil([ListenRewind validatePresets:@[@{@"steps": @[@"original"], @"slow": @-1}]], @"slow < 0");
    XCTAssertNotNil([ListenRewind validatePresets:@[@{@"steps": @[@"original"], @"slow": @2.5}]], @"non-int slow");
    XCTAssertNotNil([ListenRewind validatePresets:@[@{@"steps": @[@"original"]}]], @"missing slow");
    XCTAssertNotNil([ListenRewind validatePresets:@"x"], @"not an array");
}

- (void)testVocabSkippedOnlyWhenSectionHasNone {
    NSArray *steps = @[@"vocab", @"translation", @"original"];
    XCTAssertEqualObjects([ListenRewind playableKindsForSteps:steps hasVocab:NO], (@[@"translation", @"original"]));
    XCTAssertEqualObjects([ListenRewind playableKindsForSteps:steps hasVocab:YES], steps);
    XCTAssertEqual([ListenRewind playableKindsForSteps:@[@"vocab"] hasVocab:NO].count, 0u);
}

- (void)testNamesMatchWeb {
    XCTAssertEqualObjects([ListenRewind nameForSteps:@[@"translation", @"original"] slow:0], @"English → Original");
    XCTAssertEqualObjects([ListenRewind nameForSteps:@[@"original"] slow:20], @"Original 20% slower");
    XCTAssertEqualObjects([ListenRewind nameForSteps:@[@"translation", @"original"] slow:15], @"English → Original (original 15% slower)");
    XCTAssertEqualObjects([ListenRewind nameForSteps:@[@"original"] slow:0], @"Original");
    XCTAssertEqualObjects([ListenRewind nameForSteps:@[@"vocab", @"clear"] slow:10], @"Vocab → Clear (original 10% slower)");
}

@end
