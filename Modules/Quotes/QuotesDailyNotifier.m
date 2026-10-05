#import "QuotesDailyNotifier.h"

#import <UserNotifications/UserNotifications.h>

#import "QuotesRuleEngine.h"
#import "QuotesStore.h"

NSString *const QuotesDailyNotificationIdentifierPrefix = @"quotes-daily-";
const NSInteger QuotesDailyNotificationDaysAhead = 14;

static NSString *const kEnabledDefaultsKey = @"QuotesDailyNotifyEnabled";
static NSString *const kMinuteDefaultsKey = @"QuotesDailyNotifyMinute";
static const NSInteger kDefaultMinuteOfDay = 9 * 60;

@interface QuotesDailyEntry ()
- (instancetype)initWithIdentifier:(NSString *)identifier dateComponents:(NSDateComponents *)dateComponents quote:(GLQuote *)quote;
@end

@implementation QuotesDailyEntry
- (instancetype)initWithIdentifier:(NSString *)identifier dateComponents:(NSDateComponents *)dateComponents quote:(GLQuote *)quote {
    if ((self = [super init])) {
        _identifier = [identifier copy];
        _dateComponents = [dateComponents copy];
        _quote = quote;
    }
    return self;
}
@end

@implementation QuotesDailyNotifier

+ (BOOL)isEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kEnabledDefaultsKey];
}

+ (NSInteger)minuteOfDay {
    NSNumber *stored = [[NSUserDefaults standardUserDefaults] objectForKey:kMinuteDefaultsKey];
    return stored != nil ? stored.integerValue : kDefaultMinuteOfDay;
}

+ (void)setEnabled:(BOOL)enabled minuteOfDay:(NSInteger)minuteOfDay {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:enabled forKey:kEnabledDefaultsKey];
    [defaults setInteger:minuteOfDay forKey:kMinuteDefaultsKey];
    if (!enabled) {
        [self refresh];
        return;
    }
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        if (settings.authorizationStatus != UNAuthorizationStatusNotDetermined) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; });
            return;
        }
        [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert
                               completionHandler:^(BOOL granted, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; });
        }];
    }];
}

+ (NSArray<QuotesDailyEntry *> *)entriesFromDate:(NSDate *)now
                                        daysAhead:(NSInteger)daysAhead
                                      minuteOfDay:(NSInteger)minuteOfDay
                                            rules:(NSArray<GLQuoteRule *> *)rules
                                           quotes:(NSArray<GLQuote *> *)quotes
                             defaultRotateMinutes:(NSInteger)defaultRotateMinutes
                                         calendar:(NSCalendar *)calendar {
    NSMutableArray<QuotesDailyEntry *> *entries = [NSMutableArray array];
    NSDate *startOfToday = [calendar startOfDayForDate:now];
    for (NSInteger offset = 0; offset < daysAhead; offset++) {
        NSDate *day = [calendar dateByAddingUnit:NSCalendarUnitDay value:offset toDate:startOfToday options:0];
        NSDateComponents *fire = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitWeekday)
                                              fromDate:day];
        fire.hour = minuteOfDay / 60;
        fire.minute = minuteOfDay % 60;
        NSDate *fireDate = [calendar dateFromComponents:fire];
        if ([fireDate compare:now] != NSOrderedDescending) continue;

        QuotesSelection *selection = [QuotesRuleEngine selectionForWeekday:fire.weekday
                                                                minuteOfDay:minuteOfDay
                                                                      rules:rules
                                                                     quotes:quotes
                                                       defaultRotateMinutes:defaultRotateMinutes];
        if (selection.pool.count == 0) continue;

        NSInteger dayNumber = (NSInteger)floor(day.timeIntervalSince1970 / 86400.0);
        GLQuote *quote = selection.pool[(NSUInteger)(dayNumber % (NSInteger)selection.pool.count)];

        NSDateComponents *trigger = [[NSDateComponents alloc] init];
        trigger.year = fire.year; trigger.month = fire.month; trigger.day = fire.day;
        trigger.hour = fire.hour; trigger.minute = fire.minute;
        NSString *identifier = [NSString stringWithFormat:@"%@%04ld-%02ld-%02ld", QuotesDailyNotificationIdentifierPrefix,
                                (long)fire.year, (long)fire.month, (long)fire.day];
        [entries addObject:[[QuotesDailyEntry alloc] initWithIdentifier:identifier dateComponents:trigger quote:quote]];
    }
    return entries;
}

+ (void)refresh {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    BOOL enabled = [self isEnabled];
    NSArray<QuotesDailyEntry *> *entries = @[];
    if (enabled) {
        QuotesStore *store = [QuotesStore sharedStore];
        entries = [self entriesFromDate:[NSDate date]
                               daysAhead:QuotesDailyNotificationDaysAhead
                             minuteOfDay:[self minuteOfDay]
                                   rules:[store rules]
                                  quotes:[store allQuotes]
                    defaultRotateMinutes:[store defaultRotateMinutes]
                                calendar:[NSCalendar currentCalendar]];
    }

    // Rebuild the whole window: each day's quote is a pure function of the
    // inputs, so re-adding unchanged days is idempotent and a rule/time edit
    // takes effect immediately.
    [center getPendingNotificationRequestsWithCompletionHandler:^(NSArray<UNNotificationRequest *> *requests) {
        NSMutableArray<NSString *> *stale = [NSMutableArray array];
        for (UNNotificationRequest *request in requests) {
            if ([request.identifier hasPrefix:QuotesDailyNotificationIdentifierPrefix]) [stale addObject:request.identifier];
        }
        if (stale.count > 0) [center removePendingNotificationRequestsWithIdentifiers:stale];

        for (QuotesDailyEntry *entry in entries) {
            UNMutableNotificationContent *content = [UNMutableNotificationContent new];
            content.title = entry.quote.author.length > 0 ? entry.quote.author : @"Quote of the day";
            content.body = entry.quote.text;
            content.sound = nil;
            content.interruptionLevel = UNNotificationInterruptionLevelPassive;
            UNCalendarNotificationTrigger *trigger = [UNCalendarNotificationTrigger triggerWithDateMatchingComponents:entry.dateComponents repeats:NO];
            UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:entry.identifier content:content trigger:trigger];
            [center addNotificationRequest:request withCompletionHandler:^(NSError *error) {
                if (error) NSLog(@"[Quotes] daily notification %@ failed: %@", entry.identifier, error);
            }];
        }
    }];
}

@end
