// Pure-logic tests for what the Clips player's mic button does with a transcript.
#import <XCTest/XCTest.h>
#import "ClipsCatalog.h"
#import "ClipsVoiceCommand.h"

@interface ClipsVoiceCommandTests : XCTestCase
@end

@implementation ClipsVoiceCommandTests

- (NSArray *)sections {
    return @[@{@"id": @"a", @"name": @"A: March", @"start": @0, @"end": @75},
             @{@"id": @"b", @"name": @"B: Middle", @"start": @75, @"end": @142},
             @{@"id": @"transition", @"name": @"Transition", @"start": @142, @"end": @165},
             @{@"id": @"a2", @"name": @"A': March", @"start": @165, @"end": @213},
             @{@"id": @"coda", @"name": @"Coda", @"start": @213, @"end": @233}];
}

- (NSDictionary *)say:(NSString *)text {
    return [ClipsVoiceCommand commandFromTranscript:text sections:[self sections] playhead:40 duration:233];
}

- (void)assertNote:(NSString *)said text:(NSString *)text time:(double)time {
    NSDictionary *c = [self say:said];
    XCTAssertEqualObjects(c[@"kind"], @"note", @"%@", said);
    XCTAssertEqualObjects(c[@"text"], text, @"%@", said);
    XCTAssertEqualWithAccuracy([c[@"time"] doubleValue], time, 0.001, @"%@", said);
}

- (void)testSpokenTimes {
    NSDictionary *cases = @{@"1:23": @83, @"1.23": @83, @"83 seconds": @83, @"83.5 seconds": @83.5, @"one minute": @60,
                            @"2 minutes": @120, @"1 minute 20": @80, @"one minute and twenty seconds": @80,
                            @"one twenty": @80, @"one twenty three": @83, @"ninety": @90, @"a hundred twenty": @120,
                            @"one hundred and twenty seconds": @120, @"123": @83, @"45": @45, @"1 20": @80, @"190": @190};
    for (NSString *phrase in cases) {
        XCTAssertEqualWithAccuracy([ClipsVoiceCommand secondsFromPhrase:phrase], [cases[phrase] doubleValue], 0.001, @"%@", phrase);
    }
    for (NSString *phrase in @[@"one", @"one two", @"1:75", @"banana"]) {
        XCTAssertEqual([ClipsVoiceCommand secondsFromPhrase:phrase], -1, @"%@", phrase);
    }
}

- (void)testPlainNoteGoesAtThePlayhead {
    [self assertNote:@"left hand too loud" text:@"Left hand too loud" time:40];
    [self assertNote:@"note that the pedal is muddy" text:@"The pedal is muddy" time:40];
    [self assertNote:@"add a note: slower" text:@"Slower" time:40];
}

- (void)testSpokenTimeAtEitherEnd {
    [self assertNote:@"at 1:23 left hand too loud" text:@"Left hand too loud" time:83];
    [self assertNote:@"83 seconds in, left hand too loud" text:@"Left hand too loud" time:83];
    [self assertNote:@"at one minute twenty, rubato" text:@"Rubato" time:80];
    [self assertNote:@"at the 1:20 mark rubato" text:@"Rubato" time:80];
    [self assertNote:@"note at 45 too fast" text:@"Too fast" time:45];
    [self assertNote:@"left hand too loud at 1:23" text:@"Left hand too loud" time:83];
    [self assertNote:@"left hand too loud 83 seconds in" text:@"Left hand too loud" time:83];
}

- (void)testNumbersThatAreNotTimesStayInTheNote {
    [self assertNote:@"at one point the left hand drags" text:@"At one point the left hand drags" time:40];
    [self assertNote:@"at 90 bpm this falls apart" text:@"At 90 bpm this falls apart" time:40];
    [self assertNote:@"play this 3 times" text:@"Play this 3 times" time:40];
    [self assertNote:@"tenuto on the top note" text:@"Tenuto on the top note" time:40];
    [self assertNote:@"at bar 23 the rhythm slips" text:@"At bar 23 the rhythm slips" time:40];
}

- (void)testNoteInANamedSectionGoesToItsStart {
    [self assertNote:@"in the coda slower" text:@"Slower" time:213];
    [self assertNote:@"slower in the coda" text:@"Slower" time:213];
    [self assertNote:@"in section 2 more singing" text:@"More singing" time:75];
    [self assertNote:@"section B more singing" text:@"More singing" time:75];
    [self assertNote:@"in a hurry here" text:@"In a hurry here" time:40];
    [self assertNote:@"in the left hand watch the leaps" text:@"In the left hand watch the leaps" time:40];
}

- (void)testNoteInTheSectionBeingPlayedKeepsThePlayhead {
    [self assertNote:@"in the march keep it dry" text:@"Keep it dry" time:40];
    NSDictionary *c = [ClipsVoiceCommand commandFromTranscript:@"in the march keep it dry" sections:[self sections] playhead:180 duration:233];
    XCTAssertEqualWithAccuracy([c[@"time"] doubleValue], 180, 0.001);
}

- (void)testAnExplicitTimeBeatsANamedSection {
    [self assertNote:@"at 1:00 in the coda slower" text:@"In the coda slower" time:60];
}

- (void)testTimePastTheEndFallsBackToThePlayheadAndSaysSo {
    NSDictionary *c = [self say:@"at 9:00 too loud"];
    XCTAssertEqualObjects(c[@"text"], @"Too loud");
    XCTAssertEqualWithAccuracy([c[@"time"] doubleValue], 40, 0.001);
    XCTAssertEqualObjects(c[@"timeIgnored"], @YES);
    XCTAssertEqualObjects([self say:@"at 1:00 too loud"][@"timeIgnored"], @NO);
}

- (void)testRenameThisSection {
    for (NSString *said in @[@"this section is called the storm", @"call this section the storm", @"rename this section to the storm", @"this is called the storm"]) {
        NSDictionary *c = [self say:said];
        XCTAssertEqualObjects(c[@"kind"], @"rename", @"%@", said);
        XCTAssertEqualObjects(c[@"sectionID"], @"a", @"%@", said);
        XCTAssertEqualObjects(c[@"name"], @"The storm", @"%@", said);
    }
    XCTAssertEqualObjects([self say:@"at 1:30 this section is called the storm"][@"sectionID"], @"b");
}

- (void)testNewSectionSplitsTheOneItFallsIn {
    for (NSString *said in @[@"new section storm", @"marker storm", @"mark this as storm", @"section called storm", @"add a marker storm"]) {
        NSDictionary *c = [self say:said];
        XCTAssertEqualObjects(c[@"kind"], @"section", @"%@", said);
        XCTAssertEqualObjects(c[@"name"], @"Storm", @"%@", said);
        XCTAssertEqualWithAccuracy([c[@"start"] doubleValue], 40, 0.001, @"%@", said);
        XCTAssertEqualWithAccuracy([c[@"end"] doubleValue], 75, 0.001, @"%@", said);
        XCTAssertEqualObjects(c[@"truncateID"], @"a", @"%@", said);
    }
}

- (void)testNewSectionAtASpokenTimeOrRange {
    for (NSString *said in @[@"new section storm at 1:30", @"at 1:30 new section storm", @"1:30 is called storm", @"90 seconds is called storm"]) {
        NSDictionary *c = [self say:said];
        XCTAssertEqualObjects(c[@"kind"], @"section", @"%@", said);
        XCTAssertEqualWithAccuracy([c[@"start"] doubleValue], 90, 0.001, @"%@", said);
        XCTAssertEqualWithAccuracy([c[@"end"] doubleValue], 142, 0.001, @"%@", said);
        XCTAssertEqualObjects(c[@"truncateID"], @"b", @"%@", said);
    }
    for (NSString *said in @[@"from 1:30 to 1:45 is called storm", @"new section storm from 1:30 to 1:45"]) {
        NSDictionary *c = [self say:said];
        XCTAssertEqualWithAccuracy([c[@"start"] doubleValue], 90, 0.001, @"%@", said);
        XCTAssertEqualWithAccuracy([c[@"end"] doubleValue], 105, 0.001, @"%@", said);
    }
}

- (void)testNewSectionAtAnExistingStartRenamesIt {
    NSDictionary *c = [self say:@"new section storm at 1:15"];
    XCTAssertEqualObjects(c[@"kind"], @"rename");
    XCTAssertEqualObjects(c[@"sectionID"], @"b");
}

- (void)testSectionWithNoSectionsAround {
    NSDictionary *c = [ClipsVoiceCommand commandFromTranscript:@"this section is called intro" sections:@[] playhead:10 duration:0];
    XCTAssertEqualObjects(c[@"kind"], @"section");
    XCTAssertEqualWithAccuracy([c[@"end"] doubleValue], 20, 0.001);
    XCTAssertNil(c[@"truncateID"]);
}

- (void)testNewSectionAtTheVeryEndCoversTheLastStretch {
    NSDictionary *c = [ClipsVoiceCommand commandFromTranscript:@"new section outro" sections:[self sections] playhead:233 duration:233];
    XCTAssertEqualObjects(c[@"kind"], @"section");
    XCTAssertEqualWithAccuracy([c[@"start"] doubleValue], 223, 0.001);
    XCTAssertEqualWithAccuracy([c[@"end"] doubleValue], 233, 0.001);
    XCTAssertNil(c[@"truncateID"]);
}

- (void)testNothingToSave {
    for (NSString *said in @[@"", @"  ", @"at 1:23", @"note", @"in the coda"]) {
        XCTAssertNil([self say:said], @"%@", said);
    }
}

- (void)testManifestCarriesAnOptionalScore {
    NSData *data = [@"[{\"id\":\"x\",\"title\":\"X\",\"file\":\"x.m4a\",\"score\":\"x.pdf\"},{\"id\":\"y\",\"title\":\"Y\",\"file\":\"y.m4a\"}]" dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *clips = [ClipsCatalog clipsFromManifestData:data error:nil];
    XCTAssertEqualObjects(clips[0][@"score"], @"x.pdf");
    XCTAssertNil(clips[1][@"score"]);
    NSData *bad = [@"[{\"id\":\"x\",\"title\":\"X\",\"file\":\"x.m4a\",\"score\":\"../x.pdf\"}]" dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error = nil;
    XCTAssertNil([ClipsCatalog clipsFromManifestData:bad error:&error]);
    XCTAssertTrue([error.localizedDescription containsString:@"score"]);
}

@end
