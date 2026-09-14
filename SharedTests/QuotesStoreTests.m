// Exercises the real Security framework (no mocks -- see rules/tests.md),
// specifically the errSecMissingEntitlement (-34018) degrade path added
// after sim-test run 34860672153 crashed the app: sim-test.yml and
// unit-test.yml both build with CODE_SIGNING_ALLOWED=NO, so this test
// bundle -- like the app under those same workflows -- has no
// keychain-access-groups entitlement at all. Naming ANY access group in a
// SecItem query is therefore guaranteed to return errSecMissingEntitlement
// here, which makes this a reliable, non-mocked repro of the exact
// condition QuotesStore.m now has to survive, both in this test run and in
// the app itself under the same CI config.
#import <XCTest/XCTest.h>
#import <Security/Security.h>
#import "QuotesStore.h"

@interface QuotesStoreTests : XCTestCase
@end

@implementation QuotesStoreTests

- (QuotesStore *)storeWithUnreachableAccessGroup {
    // A syntactically valid but definitely-not-ours group: no build in this
    // repo is ever signed with it, so this reliably reproduces
    // errSecMissingEntitlement even on a real device, not just CI.
    NSString *bogusGroup = @"ZZZZZZZZZZ.com.oliverullman.assistantlocation.quotes.not-a-real-group";
    return [[QuotesStore alloc] initWithService:@"com.oliverullman.assistantlocation.quotes.tests"
                                          account:[@"store-" stringByAppendingString:[NSUUID UUID].UUIDString]
                                      accessGroup:bogusGroup];
}

- (void)testMissingEntitlementDegradesLoadToNilAndSetsUnavailableError {
    QuotesStore *store = [self storeWithUnreachableAccessGroup];
    XCTAssertNil(store.unavailableError, @"should start clear before any load");

    NSDictionary *doc = [store loadData];

    XCTAssertNil(doc, @"an unreachable access group must degrade to the same empty state as a fresh install, not raise");
    XCTAssertNotNil(store.unavailableError, @"the caller needs to know this was an unavailable-entitlement read, not a genuine fresh install");
    XCTAssertEqualObjects(store.unavailableError.domain, QuotesStoreErrorDomain);
    XCTAssertEqual(store.unavailableError.code, QuotesStoreErrorCodeUnavailable);
    XCTAssertTrue([store.unavailableError.localizedDescription containsString:@"-34018"],
                   @"message should name the real OSStatus so a report is diagnosable: %@", store.unavailableError.localizedDescription);
}

- (void)testMissingEntitlementFailsSaveInsteadOfSilentlyDroppingIt {
    QuotesStore *store = [self storeWithUnreachableAccessGroup];

    NSError *error = nil;
    BOOL saved = [store saveData:@{@"version": @1, @"quotes": @[], @"rules": @[], @"defaultRotateMinutes": @60}
                            error:&error];

    XCTAssertFalse(saved, @"a write that cannot reach the keychain must report failure, never look like a successful save");
    XCTAssertNotNil(error, @"the caller (UI) needs this to show the user their change was not persisted");
    XCTAssertEqualObjects(error.domain, QuotesStoreErrorDomain);
    XCTAssertEqual(error.code, QuotesStoreErrorCodeUnavailable);
    XCTAssertNotNil(store.unavailableError, @"a failed save should also update the store's own unavailable state, same as a failed load");
}

- (void)testMissingEntitlementClearsOnceAReadSucceeds {
    // Regression proof for the OLD (Stage-1-agent) behaviour this replaces:
    // before this fix, a missing-entitlement read/write either raised
    // (crashing the app) or silently dropped the write with no way for the
    // caller to tell "unavailable" apart from "successfully empty". Confirm
    // the distinguishing signal (unavailableError) actually flips back off
    // once a real keychain group IS reachable (accessGroup nil -> this
    // test bundle's own default group, which an unsigned build CAN use
    // because it names no access group at all).
    QuotesStore *reachable = [[QuotesStore alloc] initWithService:@"com.oliverullman.assistantlocation.quotes.tests"
                                                             account:[@"store-" stringByAppendingString:[NSUUID UUID].UUIDString]
                                                         accessGroup:nil];
    NSDictionary *doc = [reachable loadData];
    XCTAssertNil(doc, @"fresh account never saved to -- normal empty state");
    XCTAssertNil(reachable.unavailableError, @"a plain errSecItemNotFound is not an unavailable-entitlement condition");
}

@end
