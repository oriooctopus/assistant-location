#import "TodosModule.h"

#import "TodosViewController.h"

@implementation TodosModule

+ (NSString *)moduleTitle { return @"Todos"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"checklist"]; }

+ (NSInteger)moduleOrder { return 500; }

+ (UIViewController *)makeViewController {
    return [[TodosViewController alloc] init];
}

@end
