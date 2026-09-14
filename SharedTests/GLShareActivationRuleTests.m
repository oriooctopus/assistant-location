// Proves the share extension's NSExtensionActivationRule (ShareToDesktop/
// Info.plist) actually matches the items it is meant to. That rule is what
// decides whether iOS shows the "Share to desktop" icon at all, and a rule
// that parses but never matches fails silently: the icon just never appears.
//
// The rule is read from the real plist, not copied, and evaluated against the
// shape iOS evaluates it against: an object whose only key is
// "extensionItems", holding NSExtensionItems with NSItemProvider attachments.
// No substitution variables are passed, so a rule that forgets to bind
// $extensionItem itself fails here the same way it fails on the phone.
#import <XCTest/XCTest.h>
#import "GLDropUploader.h"

@interface GLShareActivationRuleTests : XCTestCase
@property(nonatomic, strong) NSPredicate *rule;
@end

@implementation GLShareActivationRuleTests

- (void)setUp {
    // Host-less logic bundle: no app bundle to read the extension's plist
    // from, so resolve it from this source file's location in the checkout.
    NSString *here = [@(__FILE__) stringByDeletingLastPathComponent];
    NSString *path = [[here stringByAppendingPathComponent:@"../ShareToDesktop/Info.plist"]
        stringByStandardizingPath];
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];
    XCTAssertNotNil(plist, @"could not read %@", path);
    NSString *format = plist[@"NSExtension"][@"NSExtensionAttributes"][@"NSExtensionActivationRule"];
    XCTAssertTrue([format isKindOfClass:[NSString class]],
                  @"activation rule must be the predicate-string form, got %@", format);
    self.rule = [NSPredicate predicateWithFormat:format];
}

- (NSItemProvider *)providerWithTypes:(NSArray<NSString *> *)types {
    NSItemProvider *provider = [[NSItemProvider alloc] init];
    for (NSString *type in types) {
        [provider registerDataRepresentationForTypeIdentifier:type
                                                    visibility:NSItemProviderRepresentationVisibilityAll
                                                   loadHandler:^NSProgress *(void (^done)(NSData *, NSError *)) {
            done([NSData data], nil);
            return nil;
        }];
    }
    return provider;
}

- (BOOL)sheetOffersAttachments:(NSArray<NSItemProvider *> *)attachments {
    NSExtensionItem *item = [[NSExtensionItem alloc] init];
    item.attachments = attachments;
    return [self.rule evaluateWithObject:@{@"extensionItems" : @[ item ]}];
}

- (void)testRuleOffersEverySupportedKindAndAgreesWithTheClassifier {
    NSDictionary<NSArray<NSString *> *, NSNumber *> *cases = @{
        @[ @"public.jpeg" ] : @YES,
        @[ @"public.png" ] : @YES,
        @[ @"com.apple.quicktime-movie" ] : @YES,
        // Voice Memos: the concrete m4a type, alone or alongside a file URL.
        @[ @"com.apple.m4a-audio" ] : @YES,
        @[ @"public.file-url", @"com.apple.m4a-audio" ] : @YES,
        @[ @"com.adobe.pdf" ] : @YES,
        @[ @"public.zip-archive" ] : @YES,
        @[ @"public.file-url" ] : @YES,
        @[ @"public.url" ] : @NO,
        @[ @"public.plain-text" ] : @NO,
    };
    [cases enumerateKeysAndObjectsUsingBlock:^(NSArray<NSString *> *types, NSNumber *offered, BOOL *stop) {
        NSItemProvider *provider = [self providerWithTypes:types];
        BOOL sheetOffers = [self sheetOffersAttachments:@[ provider ]];
        XCTAssertEqual(sheetOffers, offered.boolValue, @"rule for %@", types);
        XCTAssertEqual(sheetOffers, [GLDropUploader providerIsSupported:provider],
                       @"rule and +providerIsSupported: disagree for %@", types);
    }];
}

- (void)testRuleOffersAMixOfSupportedAndUnsupported {
    // A photo shared with its web link still has something to upload.
    NSArray *attachments = @[ [self providerWithTypes:@[ @"public.url" ]],
                              [self providerWithTypes:@[ @"public.jpeg" ]] ];
    XCTAssertTrue([self sheetOffersAttachments:attachments]);
}

- (void)testRuleRefusesMoreThanTenAttachments {
    NSMutableArray *ten = [NSMutableArray array];
    for (int i = 0; i < 10; i++) [ten addObject:[self providerWithTypes:@[ @"public.jpeg" ]]];
    XCTAssertTrue([self sheetOffersAttachments:ten]);
    NSArray *eleven = [ten arrayByAddingObject:[self providerWithTypes:@[ @"public.jpeg" ]]];
    XCTAssertFalse([self sheetOffersAttachments:eleven]);
}

- (void)testRuleRefusesAnEmptyShare {
    XCTAssertFalse([self sheetOffersAttachments:@[]]);
}

@end
