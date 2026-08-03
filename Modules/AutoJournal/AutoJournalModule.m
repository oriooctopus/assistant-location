#import "AutoJournalModule.h"

#import "AutoJournalViewController.h"

@implementation AutoJournalModule

+ (NSString *)moduleTitle { return @"Journal"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"mic.circle.fill"]; }

+ (NSInteger)moduleOrder { return 100; }

+ (UIViewController *)makeViewController {
    return [[AutoJournalViewController alloc] init];
}

@end
