#import "FootballNotificationScheduler.h"

#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>

#import "BakedConfig.h"
#import "GLLog.h"

// Same server the Football tab's WKWebView loads (FootballViewController.m)
// -- events/server.py, port 8304 -- hit directly here for JSON instead of
// the HTML view. Deliberately not Shared/GLEndpoints.h's GLEndpointURL:
// that helper is hardcoded to port 8302, the separate location/drop server.
static NSInteger const kFootballServerPort = 8304;

// Kickoff minus this many seconds -- "10 minutes before kickoff" per the
// design brief.
static NSTimeInterval const kFootballNotificationLeadSeconds = 10 * 60;

// iOS caps an app at 64 pending local notifications total and other
// features here already use some of that budget, so this scheduler caps
// its own share well under the limit rather than exhausting it on a heavy
// fixture week -- the soonest N kickoffs, not an arbitrary N of them.
static NSUInteger const kFootballNotificationCap = 30;

// Every notification this scheduler owns carries this identifier prefix
// ("fixture-<id>"), so reconcile can tell its own pending requests apart
// from any other feature's when deciding what to cancel. Scheduling a
// request with an identifier that's already pending REPLACES it rather
// than duplicating it -- that's the idempotency guarantee a reconcile on
// every tab-open/foreground/background relies on.
static NSString *const kFootballIdentifierPrefix = @"fixture-";

@implementation FootballNotificationScheduler

+ (void)reconcile {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];

    // Idempotent past the first grant/deny (same options GLManager.m's
    // -requestNotificationPermission uses) -- iOS only ever presents the
    // system prompt once regardless of how many times this is called, so a
    // reconcile on every tab-open/foreground/background is cheap. A user
    // who denies then later grants via Settings gets scheduled on the very
    // next reconcile instead of needing a relaunch.
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert + UNAuthorizationOptionSound)
                           completionHandler:^(BOOL granted, NSError * _Nullable error) {
        // Scheduling with no permission granted is a harmless no-op (iOS
        // just never presents it) -- nothing to branch on here.
    }];

    NSString *urlString = [NSString stringWithFormat:@"http://%@:%ld/api/fixtures",
                            GL_BAKED_HOST, (long)kFootballServerPort];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"FootballNotificationScheduler: %@ is not a valid URL", urlString];
    }

    // The background-entry call site is the one that matters most (see this
    // class's header), and a plain background-queue NSURLSession task can be
    // suspended mid-fetch the instant the scene finishes backgrounding.
    // Wrap the fetch + scheduling in an explicit background task so iOS
    // gives it a little real time to finish instead of killing it.
    // UIApplication is main-thread-only, and endTask below runs on
    // NSURLSession's completion queue, so both ends hop to the main queue
    // rather than touching UIKit from whatever thread happens to call.
    __block UIBackgroundTaskIdentifier bgTask = [UIApplication.sharedApplication
        beginBackgroundTaskWithExpirationHandler:^{
            [UIApplication.sharedApplication endBackgroundTask:bgTask];
            bgTask = UIBackgroundTaskInvalid;
        }];

    void (^endTask)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (bgTask != UIBackgroundTaskInvalid) {
                [UIApplication.sharedApplication endBackgroundTask:bgTask];
                bgTask = UIBackgroundTaskInvalid;
            }
        });
    };

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url
        completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error || !data) {
            GLLog(@"/api/fixtures fetch failed: %@", error);
            endTask();
            return;
        }
        NSError *jsonError = nil;
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (![parsed isKindOfClass:[NSArray class]]) {
            GLLog(@"unexpected /api/fixtures response: %@", jsonError);
            endTask();
            return;
        }
        [self reconcileWithFixtures:(NSArray *)parsed center:center completion:endTask];
    }];
    [task resume];
}

+ (void)reconcileWithFixtures:(NSArray *)fixtures
                        center:(UNUserNotificationCenter *)center
                    completion:(void (^)(void))completion {
    NSISO8601DateFormatter *isoFormatter = [[NSISO8601DateFormatter alloc] init];
    NSDate *now = [NSDate date];

    // Followed fixtures whose fire time (kickoff - 10min) hasn't passed yet,
    // soonest first -- the server already returns starts_at ascending
    // (events/db.py's list_fixtures), but sort explicitly rather than rely
    // on that ordering surviving unannounced.
    NSMutableArray<NSMutableDictionary *> *candidates = [NSMutableArray array];
    for (id fixtureObj in fixtures) {
        if (![fixtureObj isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary *fixture = (NSDictionary *)fixtureObj;
        if (![fixture[@"status"] isEqual:@"fixture_yes"]) {
            continue;
        }
        NSNumber *fixtureId = fixture[@"id"];
        NSString *startsAtUTC = fixture[@"starts_at_utc"];
        // starts_at_utc is a true external-API-boundary field -- a stray
        // malformed row (bad JSON, a server regression) is logged and
        // skipped rather than crashing the reconcile for every other
        // fixture in the same response.
        if (![startsAtUTC isKindOfClass:[NSString class]]) {
            GLLog(@"fixture %@ has no starts_at_utc, skipping", fixtureId);
            continue;
        }
        NSDate *kickoff = [isoFormatter dateFromString:startsAtUTC];
        if (!kickoff) {
            GLLog(@"unparseable starts_at_utc %@ for fixture %@, skipping", startsAtUTC, fixtureId);
            continue;
        }
        NSDate *fireDate = [kickoff dateByAddingTimeInterval:-kFootballNotificationLeadSeconds];
        if ([fireDate compare:now] != NSOrderedDescending) {
            continue; // fire time already passed -- never schedule for a moment already gone
        }
        NSMutableDictionary *withDates = [fixture mutableCopy];
        withDates[@"_fireDate"] = fireDate;
        withDates[@"_kickoff"] = kickoff;
        [candidates addObject:withDates];
    }
    [candidates sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"_fireDate"] compare:b[@"_fireDate"]];
    }];
    if (candidates.count > kFootballNotificationCap) {
        [candidates removeObjectsInRange:
            NSMakeRange(kFootballNotificationCap, candidates.count - kFootballNotificationCap)];
    }

    NSDateFormatter *timeFormatter = [[NSDateFormatter alloc] init];
    timeFormatter.dateStyle = NSDateFormatterNoStyle;
    timeFormatter.timeStyle = NSDateFormatterShortStyle;

    NSMutableSet<NSString *> *targetIdentifiers = [NSMutableSet set];
    NSMutableArray<UNNotificationRequest *> *requests = [NSMutableArray array];
    for (NSDictionary *fixture in candidates) {
        NSString *identifier = [kFootballIdentifierPrefix stringByAppendingFormat:@"%@", fixture[@"id"]];
        [targetIdentifiers addObject:identifier];

        NSDictionary *topBroadcaster = fixture[@"top_broadcaster"];
        NSString *label = [topBroadcaster isKindOfClass:[NSDictionary class]] ? topBroadcaster[@"label"] : nil;
        NSString *body;
        if ([label isKindOfClass:[NSString class]] && label.length > 0) {
            body = [NSString stringWithFormat:@"Kicks off in 10 minutes · %@", label];
        } else {
            // top_broadcaster is null (not yet assigned) -- say the kickoff
            // time instead of interpolating an empty channel name.
            NSString *kickoffTime = [timeFormatter stringFromDate:fixture[@"_kickoff"]];
            body = [NSString stringWithFormat:@"Kicks off in 10 minutes at %@", kickoffTime];
        }

        UNMutableNotificationContent *content = [UNMutableNotificationContent new];
        content.title = fixture[@"title"];
        content.body = body;
        content.sound = [UNNotificationSound defaultSound];

        NSTimeInterval interval = [fixture[@"_fireDate"] timeIntervalSinceNow];
        UNTimeIntervalNotificationTrigger *trigger =
            [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:MAX(interval, 1) repeats:NO];
        [requests addObject:[UNNotificationRequest requestWithIdentifier:identifier
                                                                   content:content
                                                                   trigger:trigger]];
    }

    [center getPendingNotificationRequestsWithCompletionHandler:^(NSArray<UNNotificationRequest *> *pending) {
        NSMutableArray<NSString *> *toCancel = [NSMutableArray array];
        for (UNNotificationRequest *req in pending) {
            // A followed fixture that's no longer returned, or that's been
            // un-swiped, must not leave a stale notification behind -- cancel
            // every one of our own identifiers that isn't in this reconcile's
            // target set.
            if ([req.identifier hasPrefix:kFootballIdentifierPrefix]
                && ![targetIdentifiers containsObject:req.identifier]) {
                [toCancel addObject:req.identifier];
            }
        }
        if (toCancel.count > 0) {
            [center removePendingNotificationRequestsWithIdentifiers:toCancel];
        }
        for (UNNotificationRequest *request in requests) {
            [center addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
                if (error) {
                    GLLog(@"failed to schedule %@: %@", request.identifier, error);
                }
            }];
        }
        if (completion) {
            completion();
        }
    }];
}

@end
