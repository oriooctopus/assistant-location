#import <UIKit/UIKit.h>

/// A clip's sheet music: one cached PDF, scrolling, pinch to zoom. Playback carries on underneath.
@interface ClipScoreViewController : UIViewController

- (instancetype)initWithFileURL:(NSURL *)fileURL;
/// Pages in the opened PDF, 0 when it could not be read.
@property (nonatomic, readonly) NSInteger pageCount;

@end
