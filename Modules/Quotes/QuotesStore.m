#import "QuotesStore.h"

#import <Security/Security.h>

#import "GLLog.h"

NS_ASSUME_NONNULL_BEGIN

static NSString *const kQuotesKeychainService = @"com.oliverullman.assistantlocation.quotes";
static NSString *const kQuotesKeychainAccount = @"store";
// Team-ID-prefixed, not the `$(AppIdentifierPrefix)` build-setting macro
// used in Overland.entitlements -- SecItem calls need the resolved value at
// runtime, and $(AppIdentifierPrefix) always resolves to the team ID here
// (single-team app, no enterprise/multi-prefix setup).
static NSString *const kQuotesKeychainAccessGroup = @"J66WVM2DTX.com.oliverullman.assistantlocation.quotes";

static NSInteger const kQuotesDocumentVersion = 1;
static NSInteger const kQuotesDefaultRotateMinutesFallback = 60;

NSString *const QuotesStoreErrorDomain = @"QuotesStoreErrorDomain";

static NSError *QuotesStoreUnavailableErrorWithStatus(OSStatus status) {
    NSString *message = [NSString stringWithFormat:@"keychain unavailable (OSStatus %d)", (int)status];
    return [NSError errorWithDomain:QuotesStoreErrorDomain
                                code:QuotesStoreErrorCodeUnavailable
                            userInfo:@{NSLocalizedDescriptionKey: message}];
}

@interface QuotesStore ()
@property(nonatomic, copy, readonly) NSString *service;
@property(nonatomic, copy, readonly) NSString *account;
@property(nonatomic, copy, readonly, nullable) NSString *accessGroup;
@property(nonatomic, strong, readonly) NSArray<GLQuote *> *stockQuotes;
@property(nonatomic, strong, readwrite, nullable) NSError *unavailableError;
@end

@implementation QuotesStore

+ (instancetype)sharedStore {
    static QuotesStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        store = [[QuotesStore alloc] initWithService:kQuotesKeychainService
                                               account:kQuotesKeychainAccount
                                           accessGroup:kQuotesKeychainAccessGroup];
    });
    return store;
}

- (instancetype)initWithService:(NSString *)service
                          account:(NSString *)account
                      accessGroup:(nullable NSString *)accessGroup {
    self = [super init];
    if (self) {
        _service = [service copy];
        _account = [account copy];
        _accessGroup = [accessGroup copy];
        _stockQuotes = [QuotesStore loadStockQuotesFromBundle];
    }
    return self;
}

#pragma mark - stock-quotes.json

// Modules/ is a PBXFileSystemSynchronizedRootGroup (see MODULES.md); like
// GLWebModuleViewController's -initWithBundledPageNamed:, there is no
// compiler on this box to confirm whether Xcode's synchronized-group
// resource copy nests stock-quotes.json under a "Quotes" subdirectory or
// flattens it into the bundle root, so both are tried before raising.
+ (NSArray<GLQuote *> *)loadStockQuotesFromBundle {
    NSBundle *bundle = [NSBundle mainBundle];
    NSURL *fileURL = [bundle URLForResource:@"stock-quotes" withExtension:@"json" subdirectory:@"Quotes"];
    if (fileURL == nil) {
        fileURL = [bundle URLForResource:@"stock-quotes" withExtension:@"json"];
    }
    if (fileURL == nil) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"stock-quotes.json not found in the app bundle (checked Quotes/ and the "
                            "bundle root) -- check that Modules/'s file-system-synchronized group is "
                            "copying .json resources into the build product"];
    }

    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfURL:fileURL options:0 error:&readError];
    if (data == nil) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"could not read stock-quotes.json at %@: %@", fileURL, readError];
    }

    NSError *jsonError = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (jsonError || ![parsed isKindOfClass:[NSArray class]]) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"stock-quotes.json did not parse as a JSON array: %@", jsonError];
    }

    NSMutableArray<GLQuote *> *quotes = [NSMutableArray array];
    for (id entry in (NSArray *)parsed) {
        NSMutableDictionary *withSource = [entry isKindOfClass:[NSDictionary class]] ? [(NSDictionary *)entry mutableCopy] : nil;
        withSource[@"source"] = GLQuoteSourceStock;
        GLQuote *quote = [GLQuote quoteFromDictionary:withSource];
        if (quote != nil) {
            [quotes addObject:quote];
        } else {
            GLLog(@"dropped malformed stock quote entry: %@", entry);
        }
    }
    return quotes;
}

#pragma mark - Keychain load/save

- (NSMutableDictionary<NSString *, id> *)baseQuery {
    NSMutableDictionary<NSString *, id> *query = [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: self.service,
        (__bridge id)kSecAttrAccount: self.account,
    } mutableCopy];
    if (self.accessGroup != nil) {
        query[(__bridge id)kSecAttrAccessGroup] = self.accessGroup;
    }
    return query;
}

- (nullable NSDictionary<NSString *, id> *)loadData {
    NSMutableDictionary<NSString *, id> *query = [self baseQuery];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;

    CFTypeRef resultRef = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &resultRef);
    if (status == errSecItemNotFound) {
        self.unavailableError = nil; // fresh install / never saved -- the normal empty state, not an error
        return nil;
    }
    if (status == errSecMissingEntitlement) {
        // The keychain-access-groups entitlement isn't applied in this
        // process (unsigned CI simulator builds -- CODE_SIGNING_ALLOWED=NO
        // in sim-test.yml -- or, on device, a provisioning mismatch). Either
        // way the shared store is genuinely unreachable here, not corrupt --
        // but unlike a fresh install, the caller (Quotes tab / widget) must
        // tell the user, since imports/rules could actually exist and just
        // be unreadable right now. Record it for the caller and degrade to
        // an empty document (stock quotes only) rather than crash.
        GLLog(@"SecItemCopyMatching missing keychain entitlement for the quotes store (OSStatus %d)", (int)status);
        self.unavailableError = QuotesStoreUnavailableErrorWithStatus(status);
        return nil;
    }
    if (status != errSecSuccess) {
        GLLog(@"SecItemCopyMatching failed for the quotes store: OSStatus %d", (int)status);
        [NSException raise:@"QuotesStoreKeychainError" format:@"SecItemCopyMatching failed: OSStatus %d", (int)status];
        return nil;
    }

    NSData *data = (__bridge_transfer NSData *)resultRef;
    NSError *jsonError = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (jsonError || ![parsed isKindOfClass:[NSDictionary class]]) {
        [NSException raise:@"QuotesStoreCorruptError"
                    format:@"quotes store keychain item did not parse as a JSON object: %@", jsonError];
        return nil;
    }
    self.unavailableError = nil; // a real read succeeded -- clear any earlier unavailable state
    return parsed;
}

- (BOOL)saveData:(NSDictionary<NSString *, id> *)data error:(NSError **)error {
    NSError *jsonError = nil;
    NSData *payload = [NSJSONSerialization dataWithJSONObject:data options:0 error:&jsonError];
    if (jsonError || payload == nil) {
        [NSException raise:@"QuotesStoreSerializeError" format:@"could not serialize the quotes store: %@", jsonError];
        return NO;
    }

    NSMutableDictionary<NSString *, id> *query = [self baseQuery];
    NSDictionary<NSString *, id> *update = @{(__bridge id)kSecValueData: payload};

    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)update);
    if (status == errSecItemNotFound) {
        NSMutableDictionary<NSString *, id> *insert = [query mutableCopy];
        insert[(__bridge id)kSecValueData] = payload;
        // AfterFirstUnlock, not WhenUnlocked: the widget extension (Stage 2)
        // must be able to read this while the phone is locked -- see the
        // coordinator's directive that changed this class from a plain file
        // to a shared keychain item.
        insert[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
        status = SecItemAdd((__bridge CFDictionaryRef)insert, NULL);
    }
    if (status == errSecMissingEntitlement) {
        // Same condition as -loadData's errSecMissingEntitlement branch:
        // this process has no keychain-access-groups entitlement at all (an
        // unsigned CI simulator build, or an on-device provisioning
        // mismatch), so the write can never succeed here. Unlike the old
        // behaviour, this must NOT look like a successful save to the
        // caller -- report failure so the UI can tell the user the change
        // was not persisted, rather than silently dropping it. A real,
        // signed build never takes this path (see Overland.entitlements'
        // `J66WVM2DTX.*` group).
        GLLog(@"SecItem write missing keychain entitlement for the quotes store (OSStatus %d) -- write NOT saved", (int)status);
        NSError *unavailable = QuotesStoreUnavailableErrorWithStatus(status);
        self.unavailableError = unavailable;
        if (error != NULL) *error = unavailable;
        return NO;
    }
    if (status != errSecSuccess) {
        GLLog(@"SecItem write failed for the quotes store: OSStatus %d", (int)status);
        [NSException raise:@"QuotesStoreKeychainError" format:@"SecItem write failed: OSStatus %d", (int)status];
        return NO;
    }
    self.unavailableError = nil; // a real write succeeded -- clear any earlier unavailable state
    return YES;
}

#pragma mark - Document helpers

- (NSDictionary<NSString *, id> *)documentOrEmpty {
    NSDictionary<NSString *, id> *doc = [self loadData];
    if (doc != nil) return doc;
    return @{
        @"version": @(kQuotesDocumentVersion),
        @"quotes": @[],
        @"rules": @[],
        @"defaultRotateMinutes": @(kQuotesDefaultRotateMinutesFallback),
    };
}

- (NSArray<GLQuote *> *)importedQuotesFromDocument:(NSDictionary<NSString *, id> *)doc {
    NSArray *raw = doc[@"quotes"];
    if (![raw isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray<GLQuote *> *quotes = [NSMutableArray array];
    for (id entry in raw) {
        GLQuote *quote = [GLQuote quoteFromDictionary:entry];
        if (quote != nil) {
            [quotes addObject:quote];
        } else {
            GLLog(@"dropped malformed imported quote entry: %@", entry);
        }
    }
    return quotes;
}

#pragma mark - Quotes

- (NSArray<GLQuote *> *)allQuotes {
    NSDictionary<NSString *, id> *doc = [self documentOrEmpty];
    NSArray<GLQuote *> *imported = [self importedQuotesFromDocument:doc];

    NSMutableDictionary<NSString *, GLQuote *> *byId = [NSMutableDictionary dictionary];
    for (GLQuote *quote in self.stockQuotes) byId[quote.quoteId] = quote;
    for (GLQuote *quote in imported) byId[quote.quoteId] = quote; // imported wins on an id collision

    NSMutableArray<GLQuote *> *ordered = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (GLQuote *quote in self.stockQuotes) {
        if ([seen containsObject:quote.quoteId]) continue;
        [ordered addObject:byId[quote.quoteId]];
        [seen addObject:quote.quoteId];
    }
    for (GLQuote *quote in imported) {
        if ([seen containsObject:quote.quoteId]) continue;
        [ordered addObject:quote];
        [seen addObject:quote.quoteId];
    }
    return ordered;
}

- (NSArray<NSString *> *)knownAuthors {
    NSMutableSet<NSString *> *authors = [NSMutableSet set];
    for (GLQuote *quote in self.allQuotes) [authors addObject:quote.author];
    return [[authors allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

- (NSArray<NSString *> *)knownGenres {
    NSMutableSet<NSString *> *genres = [NSMutableSet set];
    for (GLQuote *quote in self.allQuotes) [genres addObjectsFromArray:quote.genres];
    return [[genres allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

- (BOOL)addImportedQuotes:(NSArray<GLQuote *> *)quotes error:(NSError **)error {
    if (quotes.count == 0) return YES;
    NSMutableDictionary<NSString *, id> *doc = [[self documentOrEmpty] mutableCopy];
    NSMutableArray<NSDictionary *> *existing = [(NSArray *)(doc[@"quotes"] ?: @[]) mutableCopy];
    for (GLQuote *quote in quotes) [existing addObject:[quote toDictionary]];
    doc[@"quotes"] = existing;
    doc[@"version"] = @(kQuotesDocumentVersion);
    return [self saveData:doc error:error];
}

- (BOOL)deleteImportedQuoteWithId:(NSString *)quoteId error:(NSError **)error {
    NSMutableDictionary<NSString *, id> *doc = [[self documentOrEmpty] mutableCopy];
    NSArray<GLQuote *> *imported = [self importedQuotesFromDocument:doc];
    NSMutableArray<NSDictionary *> *remaining = [NSMutableArray array];
    for (GLQuote *quote in imported) {
        if (![quote.quoteId isEqualToString:quoteId]) [remaining addObject:[quote toDictionary]];
    }
    doc[@"quotes"] = remaining;
    doc[@"version"] = @(kQuotesDocumentVersion);
    return [self saveData:doc error:error];
}

#pragma mark - Rules

- (NSArray<GLQuoteRule *> *)rules {
    NSDictionary<NSString *, id> *doc = [self documentOrEmpty];
    NSArray *raw = doc[@"rules"];
    if (![raw isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray<GLQuoteRule *> *rules = [NSMutableArray array];
    for (id entry in raw) {
        GLQuoteRule *rule = [GLQuoteRule ruleFromDictionary:entry];
        if (rule != nil) {
            [rules addObject:rule];
        } else {
            GLLog(@"dropped malformed rule entry: %@", entry);
        }
    }
    return rules;
}

- (BOOL)saveRules:(NSArray<GLQuoteRule *> *)rules error:(NSError **)error {
    NSMutableDictionary<NSString *, id> *doc = [[self documentOrEmpty] mutableCopy];
    NSMutableArray<NSDictionary *> *serialized = [NSMutableArray arrayWithCapacity:rules.count];
    for (GLQuoteRule *rule in rules) [serialized addObject:[rule toDictionary]];
    doc[@"rules"] = serialized;
    doc[@"version"] = @(kQuotesDocumentVersion);
    return [self saveData:doc error:error];
}

- (NSInteger)defaultRotateMinutes {
    NSDictionary<NSString *, id> *doc = [self documentOrEmpty];
    id value = doc[@"defaultRotateMinutes"];
    if ([value isKindOfClass:[NSNumber class]] && [(NSNumber *)value integerValue] > 0) {
        return [(NSNumber *)value integerValue];
    }
    return kQuotesDefaultRotateMinutesFallback;
}

- (BOOL)setDefaultRotateMinutes:(NSInteger)minutes error:(NSError **)error {
    NSMutableDictionary<NSString *, id> *doc = [[self documentOrEmpty] mutableCopy];
    doc[@"defaultRotateMinutes"] = @(minutes > 0 ? minutes : kQuotesDefaultRotateMinutesFallback);
    doc[@"version"] = @(kQuotesDocumentVersion);
    return [self saveData:doc error:error];
}

@end

NS_ASSUME_NONNULL_END
