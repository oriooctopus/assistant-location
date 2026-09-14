// Format-coverage tests for QuotesImportParser: each recognized
// quote/author separator, curly vs straight quotes, CSV, one-per-line vs
// blank-line-separated blocks, and the dedupe normalization helper.
#import <XCTest/XCTest.h>
#import "QuotesImportParser.h"

@interface QuotesImportParserTests : XCTestCase
@end

@implementation QuotesImportParserTests

#pragma mark - Single-entry formats

- (void)testStraightQuotesWithEmDash {
    QuotesParsedQuote *q = [QuotesImportParser parseOneEntry:@"\"Be yourself.\" — Oscar Wilde"];
    XCTAssertEqualObjects(q.text, @"Be yourself.");
    XCTAssertEqualObjects(q.author, @"Oscar Wilde");
}

- (void)testCurlyQuotesWithEmDash {
    QuotesParsedQuote *q = [QuotesImportParser parseOneEntry:@"“Be yourself.” — Oscar Wilde"];
    XCTAssertEqualObjects(q.text, @"Be yourself.");
    XCTAssertEqualObjects(q.author, @"Oscar Wilde");
}

- (void)testPlainHyphenSeparator {
    QuotesParsedQuote *q = [QuotesImportParser parseOneEntry:@"Be yourself - Oscar Wilde"];
    XCTAssertEqualObjects(q.text, @"Be yourself");
    XCTAssertEqualObjects(q.author, @"Oscar Wilde");
}

- (void)testEnDashSeparator {
    QuotesParsedQuote *q = [QuotesImportParser parseOneEntry:@"Be yourself – Oscar Wilde"];
    XCTAssertEqualObjects(q.text, @"Be yourself");
    XCTAssertEqualObjects(q.author, @"Oscar Wilde");
}

- (void)testTildeSeparator {
    QuotesParsedQuote *q = [QuotesImportParser parseOneEntry:@"Be yourself ~ Oscar Wilde"];
    XCTAssertEqualObjects(q.text, @"Be yourself");
    XCTAssertEqualObjects(q.author, @"Oscar Wilde");
}

- (void)testCSVFormat {
    QuotesParsedQuote *q = [QuotesImportParser parseOneEntry:@"Be yourself.,Oscar Wilde"];
    XCTAssertEqualObjects(q.text, @"Be yourself.");
    XCTAssertEqualObjects(q.author, @"Oscar Wilde");
}

- (void)testNoRecognizedSeparatorFallsBackToUnknownAuthor {
    QuotesParsedQuote *q = [QuotesImportParser parseOneEntry:@"Just a plain sentence with no attribution"];
    XCTAssertEqualObjects(q.text, @"Just a plain sentence with no attribution");
    XCTAssertEqualObjects(q.author, @"Unknown");
}

- (void)testInternalHyphenatedWordDoesNotFalselySplit {
    // "well-known" has no whitespace around its hyphen, so the dash regex
    // (which requires whitespace on both sides) must not treat it as a
    // separator -- the real attribution dash later in the string wins.
    QuotesParsedQuote *q = [QuotesImportParser parseOneEntry:@"A well-known truth - Anonymous"];
    XCTAssertEqualObjects(q.text, @"A well-known truth");
    XCTAssertEqualObjects(q.author, @"Anonymous");
}

- (void)testSplitsOnTheLastSeparatorNotTheFirst {
    // The quote text itself contains an em dash; only the trailing,
    // whitespace-bounded one before the author should be treated as the
    // separator (greedy match).
    QuotesParsedQuote *q = [QuotesImportParser parseOneEntry:@"Fear is the mind-killer — I will face my fear — Frank Herbert"];
    XCTAssertEqualObjects(q.text, @"Fear is the mind-killer — I will face my fear");
    XCTAssertEqualObjects(q.author, @"Frank Herbert");
}

#pragma mark - Batch splitting

- (void)testOnePerLineWhenNoBlankLines {
    NSArray<QuotesParsedQuote *> *parsed = [QuotesImportParser parseText:@"\"A\" — Author1\n\"B\" — Author2\n\"C\" — Author3"];
    XCTAssertEqual(parsed.count, 3u);
    XCTAssertEqualObjects(parsed[0].text, @"A");
    XCTAssertEqualObjects(parsed[1].author, @"Author2");
    XCTAssertEqualObjects(parsed[2].text, @"C");
}

- (void)testBlankLineSeparatedBlocksJoinInternalNewlines {
    NSString *input = @"This quote\nwraps across two lines\n— Author One\n\nA second quote — Author Two";
    NSArray<QuotesParsedQuote *> *parsed = [QuotesImportParser parseText:input];
    XCTAssertEqual(parsed.count, 2u);
    XCTAssertEqualObjects(parsed[0].text, @"This quote wraps across two lines");
    XCTAssertEqualObjects(parsed[0].author, @"Author One");
    XCTAssertEqualObjects(parsed[1].text, @"A second quote");
    XCTAssertEqualObjects(parsed[1].author, @"Author Two");
}

- (void)testEmptyInputProducesNoEntries {
    XCTAssertEqual([QuotesImportParser parseText:@""].count, 0u);
}

#pragma mark - Dedupe normalization

- (void)testNormalizeTextForDedupeIgnoresCaseAndPunctuation {
    NSString *a = [QuotesImportParser normalizeTextForDedupe:@"Be Yourself; everyone else is taken!"];
    NSString *b = [QuotesImportParser normalizeTextForDedupe:@"be yourself, everyone else is taken"];
    XCTAssertEqualObjects(a, b);
}

- (void)testNormalizeTextForDedupeDistinguishesDifferentText {
    NSString *a = [QuotesImportParser normalizeTextForDedupe:@"Be yourself."];
    NSString *b = [QuotesImportParser normalizeTextForDedupe:@"Be someone else."];
    XCTAssertNotEqualObjects(a, b);
}

@end
