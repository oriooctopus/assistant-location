#import "GLDurableOutboxShared.h"

#import <UserNotifications/UserNotifications.h>

#import "BakedConfig.h"
#import "GLEndpoints.h"

@implementation GLDurableOutbox (Shared)

// Everything testable (directory, flush on start and on app-active, the retry
// timer, quarantine) lives in GLDurableOutbox, which SharedTests exercise.
// This is only the app-specific wiring: endpoint, token, and the user alert.
+ (GLDurableOutbox *)shared {
    static GLDurableOutbox *outbox;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        outbox = [[GLDurableOutbox alloc] initWithDirectory:[GLDurableOutbox defaultDirectory]
                                                 urlBuilder:^NSURL *(NSString *path) { return GLEndpointURL(path); }
                                                      token:GL_BAKED_TOKEN
                                       sessionConfiguration:nil];
        [[NSNotificationCenter defaultCenter] addObserverForName:GLDurableOutboxDidQuarantineNotification
                                                          object:outbox
                                                           queue:nil
                                                      usingBlock:^(NSNotification *note) {
            UNMutableNotificationContent *content = [UNMutableNotificationContent new];
            content.title = @"An unsent item was damaged";
            content.body = @"A saved note, photo or reply could not be read, so it was set aside instead of sent. Its content is still on the phone.";
            content.sound = [UNNotificationSound defaultSound];
            NSString *identifier = [@"GLDurableQuarantined-" stringByAppendingString:note.userInfo[@"id"]];
            [[UNUserNotificationCenter currentNotificationCenter]
                addNotificationRequest:[UNNotificationRequest requestWithIdentifier:identifier content:content trigger:nil]
                 withCompletionHandler:^(NSError *error) {
                if (error) NSLog(@"Quarantine notification failed: %@", error);
            }];
        }];
        [outbox startDraining];
    });
    return outbox;
}

@end
