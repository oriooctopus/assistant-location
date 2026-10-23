#import "CycleBridge.h"

#import <UIKit/UIKit.h>

#import "CycleNotifier.h"
#import "CycleStore.h"

typedef void (^CycleResult)(id result, NSString *error);

@interface CycleBridge ()
@property (nonatomic, strong) CycleStore *store;
@property (nonatomic, strong) CycleNotifier *notifier;
@property (nonatomic, assign) BOOL ready;
@property (nonatomic, strong) NSMutableArray<NSString *> *queuedRoutes;
@end

@implementation CycleBridge

- (instancetype)initWithStore:(CycleStore *)store notifier:(CycleNotifier *)notifier {
    if ((self = [super init])) {
        _store = store;
        _notifier = notifier;
        _queuedRoutes = [NSMutableArray array];
    }
    return self;
}

- (void)callNative:(NSString *)method arguments:(NSArray *)arguments {
    NSData *json = [NSJSONSerialization dataWithJSONObject:arguments options:0 error:NULL];
    NSString *args = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    self.evaluateJS([NSString stringWithFormat:@"window.cycleNative.%@.apply(window.cycleNative, %@)", method, args]);
}

- (void)reply:(id)ident result:(id)result error:(NSString *)error {
    NSData *json = [NSJSONSerialization dataWithJSONObject:@[ident ?: NSNull.null, result ?: NSNull.null, error ?: NSNull.null] options:0 error:NULL];
    NSString *args = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    self.evaluateJS([NSString stringWithFormat:@"window.__cycleReply.apply(null, %@)", args]);
}

- (void)handleMessage:(id)body {
    NSAssert([body isKindOfClass:NSDictionary.class], @"bridge message is not a dictionary: %@", body);
    NSDictionary *msg = body;
    id ident = msg[@"id"];
    NSString *cmd = msg[@"cmd"];
    NSDictionary *args = [msg[@"args"] isKindOfClass:NSDictionary.class] ? msg[@"args"] : @{};
    __weak typeof(self) weakSelf = self;
    [self dispatchCommand:cmd args:args completion:^(id result, NSString *error) {
        if (error) NSLog(@"[Cycle] %@ failed: %@", cmd, error);
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf reply:ident result:result error:error]; });
    }];
}

- (void)dispatchCommand:(NSString *)cmd args:(NSDictionary *)args completion:(CycleResult)done {
    NSError *nsError = nil;
    if ([cmd isEqualToString:@"store.get"]) {
        NSString *key = args[@"key"];
        if (![key isKindOfClass:NSString.class]) { done(nil, @"store.get: 'key' must be a string"); return; }
        done([self.store valueForKey:key], nil);
    } else if ([cmd isEqualToString:@"store.set"]) {
        NSString *key = args[@"key"];
        id value = args[@"value"];
        if (![key isKindOfClass:NSString.class]) { done(nil, @"store.set: 'key' must be a string"); return; }
        if (value == NSNull.null || value == nil) value = nil;
        else if (![value isKindOfClass:NSString.class]) { done(nil, @"store.set: 'value' must be a string or null"); return; }
        if ([self.store setValue:value forKey:key error:&nsError]) done(NSNull.null, nil);
        else done(nil, nsError.localizedDescription);
    } else if ([cmd isEqualToString:@"store.keys"]) {
        NSString *prefix = args[@"prefix"];
        if (![prefix isKindOfClass:NSString.class]) { done(nil, @"store.keys: 'prefix' must be a string"); return; }
        done([self.store keysWithPrefix:prefix], nil);
    } else if ([cmd isEqualToString:@"notify.permission"]) {
        [self.notifier permissionWithCompletion:^(BOOL granted) { done(@(granted), nil); }];
    } else if ([cmd isEqualToString:@"notify.schedule"]) {
        [self.notifier scheduleArgs:args now:[NSDate date] completion:^(NSError *error) {
            if (error) done(nil, error.localizedDescription); else done(NSNull.null, nil);
        }];
    } else if ([cmd isEqualToString:@"notify.cancel"]) {
        NSString *ident = args[@"id"];
        if (![ident isKindOfClass:NSString.class]) { done(nil, @"notify.cancel: 'id' must be a string"); return; }
        [self.notifier cancelID:ident];
        done(NSNull.null, nil);
    } else if ([cmd isEqualToString:@"haptic"]) {
        NSString *kind = args[@"kind"];
        if ([kind isEqualToString:@"light"]) {
            [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
        } else if ([kind isEqualToString:@"success"]) {
            [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
        } else if ([kind isEqualToString:@"warning"]) {
            [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeWarning];
        } else {
            done(nil, [NSString stringWithFormat:@"haptic: unknown kind %@", kind]);
            return;
        }
        done(NSNull.null, nil);
    } else if ([cmd isEqualToString:@"share"]) {
        NSString *filename = args[@"filename"];
        NSString *text = args[@"text"];
        if (![filename isKindOfClass:NSString.class] || filename.length == 0) { done(nil, @"share: 'filename' must be a non-empty string"); return; }
        if (![text isKindOfClass:NSString.class]) { done(nil, @"share: 'text' must be a string"); return; }
        if ([filename containsString:@"/"] || [filename isEqualToString:@"."] || [filename isEqualToString:@".."]) {
            done(nil, [NSString stringWithFormat:@"share: 'filename' %@ must not contain a path", filename]);
            return;
        }
        NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:filename]];
        if (![text writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:&nsError]) {
            done(nil, [NSString stringWithFormat:@"share: could not write %@: %@", filename, nsError.localizedDescription]);
            return;
        }
        self.presentFile(url);
        done(@YES, nil);
    } else if ([cmd isEqualToString:@"ready"]) {
        done(NSNull.null, nil);
        self.ready = YES;
        NSArray *queued = [self.queuedRoutes copy];
        [self.queuedRoutes removeAllObjects];
        for (NSString *route in queued) [self callNative:@"route" arguments:@[route]];
    } else {
        done(nil, [NSString stringWithFormat:@"unsupported bridge command %@", cmd]);
    }
}

- (void)deliverRoute:(NSString *)route {
    if (self.ready) [self callNative:@"route" arguments:@[route]];
    else [self.queuedRoutes addObject:route];
}

- (void)foreground {
    if (self.ready) [self callNative:@"foreground" arguments:@[]];
}

- (void)pageWillReload {
    self.ready = NO;
}

@end
