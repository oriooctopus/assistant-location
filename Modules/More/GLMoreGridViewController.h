// The "More" screen: a two-column grid of large tiles, one per module that
// didn't fit in the tab bar, replacing the plain UIKit table list UIKit
// builds for its More bucket.
//
// Why this exists at all: UITabBarController shows at most 5 tabs and pushes
// the rest into a system list. That list looked nothing like the rest of the
// app — rows crammed against the tab bar with the last one clipped by it,
// two thirds of the screen empty above them, a surface-coloured slab on a
// differently-coloured page, and a stray "Edit" button. This replaces the
// list wholesale rather than trying to restyle a table UIKit owns and
// rebuilds behind our back.
//
// It is installed as the ROOT of `tabBarController.moreNavigationController`
// (see GLModuleRegistry +installIntoTabBarController:), NOT as a tab of its
// own. That is deliberate: it keeps every existing path that assumes the
// overflow modules live in the More bucket working unchanged — the tab
// INDEX of each module, SceneDelegate's UITEST_TAB hook, AutoJournal's
// -selectJournalTab, and the module VCs' own nesting (Journal wraps itself
// in a navigation controller, which UIKit's More stack already tolerated).
// Tapping a tile pushes onto exactly the navigation controller UIKit would
// have pushed onto anyway.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface GLMoreGridViewController : UIViewController

/// `moduleViewControllers` are the already-built module view controllers that
/// overflowed the tab bar, in module order. Their `title` and
/// `tabBarItem.image` supply each tile's label and glyph, and their
/// `restorationIdentifier` is the stable key the saved order and the saved
/// hero flags are stored against — so reordering the tiles, or adding or
/// removing a module, never invalidates the saved arrangement by index.
- (instancetype)initWithModuleViewControllers:(NSArray<UIViewController *> *)moduleViewControllers
    NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithNibName:(nullable NSString *)nib bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
