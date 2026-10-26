#import <UIKit/UIKit.h>

@interface ClipsViewController : UIViewController

/// Plays the clip with this id: right away when it is known and cached,
/// otherwise as soon as the manifest and file are available.
- (void)playClipWithID:(NSString *)clipID;

@end
