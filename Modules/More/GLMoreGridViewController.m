#import "GLMoreGridViewController.h"

#import "GLDefaultsKeys.h"
#import "GLTheme.h"

#pragma mark - Metrics

// GLTheme's own +cornerRadius is 10 — the radius of a CONTROL (a button, a
// text field). These tiles are roughly 170pt squares, and 10 on a box that
// size reads as an almost-square corner. This is a card radius, deliberately
// its own number rather than a reuse of the control one.
static CGFloat const kTileCornerRadius = 24.0;
// The rounded square the glyph sits in, inside each tile.
static CGFloat const kIconChipSide = 60.0;
static CGFloat const kIconChipCornerRadius = 17.0;
static CGFloat const kIconPointSize = 27.0;
// How far a finger must travel after the long press before a drag actually
// starts moving tiles. Without it, the tiny jitter of holding still makes
// the grid twitch the instant the press is recognised.
static CGFloat const kDragSlop = 4.0;

#pragma mark - Tile

// One tile. Deliberately a plain UIView with a tap gesture rather than a
// UIButton: the tile has to be draggable, and a UIButton's own touch
// tracking fights a long-press-then-drag for the same touch.
@interface GLMoreTileView : UIView
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, strong) UIViewController *moduleViewController;
@property (nonatomic, assign, getter=isHero) BOOL hero;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIView *iconChip;
@property (nonatomic, strong) UIImageView *iconView;
/// Shown only in edit mode: toggles this tile between one column and two.
@property (nonatomic, strong) UIButton *resizeBadge;

/// Re-reads every colour from GLTheme. Declared here, not merely defined in
/// the implementation below, because the grid controller further down this
/// file calls it — a method only defined in an @implementation is invisible
/// to code in a different class, even in the same file.
- (void)applyTheme;
@end

@implementation GLMoreTileView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.layer.cornerRadius = kTileCornerRadius;
    // Continuous ("squircle") corners, matching the iOS home screen and the
    // app icons these tiles sit next to. The circular default reads as a
    // rounded rectangle at this size; continuous reads as a tile.
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.clipsToBounds = NO;

    _iconChip = [[UIView alloc] initWithFrame:CGRectZero];
    _iconChip.layer.cornerRadius = kIconChipCornerRadius;
    _iconChip.layer.cornerCurve = kCACornerCurveContinuous;
    _iconChip.userInteractionEnabled = NO;
    [self addSubview:_iconChip];

    _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    _iconView.userInteractionEnabled = NO;
    [_iconChip addSubview:_iconView];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.adjustsFontSizeToFitWidth = YES;
    _titleLabel.minimumScaleFactor = 0.75;
    _titleLabel.userInteractionEnabled = NO;
    [self addSubview:_titleLabel];

    _resizeBadge = [UIButton buttonWithType:UIButtonTypeSystem];
    _resizeBadge.hidden = YES;
    [self addSubview:_resizeBadge];

    [self applyTheme];
    return self;
}

- (void)applyTheme {
    self.backgroundColor = [GLTheme surfaceColor];
    self.titleLabel.textColor = [GLTheme textPrimaryColor];
    self.titleLabel.font = [GLTheme buttonFont];
    self.iconView.tintColor = [GLTheme accentColor];
    // A tint of the accent behind the glyph, not the flat accent: at this
    // size a fully saturated chip pulls the eye away from the label and
    // makes every tile compete with every other one.
    self.iconChip.backgroundColor = [[GLTheme accentColor] colorWithAlphaComponent:0.18];
    self.resizeBadge.tintColor = [GLTheme accentColor];
    self.resizeBadge.backgroundColor = [GLTheme backgroundColor];

    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.18;
    self.layer.shadowRadius = 12.0;
    self.layer.shadowOffset = CGSizeMake(0, 6);
}

- (void)setHero:(BOOL)hero {
    _hero = hero;
    UIImage *glyph = [UIImage systemImageNamed:hero ? @"arrow.down.right.and.arrow.up.left"
                                                    : @"arrow.up.left.and.arrow.down.right"];
    [self.resizeBadge setImage:glyph forState:UIControlStateNormal];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;

    // Icon chip and label are treated as one stacked block and centred
    // together, so a hero tile (short and wide) and a standard tile (square)
    // both read as "glyph above label, centred" rather than the hero's
    // content drifting to the top of a much shorter box.
    CGFloat labelHeight = ceil(self.titleLabel.font.lineHeight);
    CGFloat gap = [GLTheme spacingS];
    CGFloat blockHeight = kIconChipSide + gap + labelHeight;
    CGFloat top = floor((h - blockHeight) / 2.0);

    self.iconChip.frame = CGRectMake(floor((w - kIconChipSide) / 2.0), top,
                                     kIconChipSide, kIconChipSide);
    CGFloat inset = floor((kIconChipSide - kIconPointSize) / 2.0);
    self.iconView.frame = CGRectInset(self.iconChip.bounds, inset, inset);
    self.titleLabel.frame = CGRectMake([GLTheme spacingXS], top + kIconChipSide + gap,
                                       w - 2 * [GLTheme spacingXS], labelHeight);

    CGFloat badge = 30.0;
    self.resizeBadge.frame = CGRectMake(w - badge - [GLTheme spacingXS], [GLTheme spacingXS],
                                        badge, badge);
    self.resizeBadge.layer.cornerRadius = badge / 2.0;

    // Rasterised shadow path rather than letting Core Animation derive one
    // from the (non-opaque, continuous-corner) layer every frame — this view
    // is animated during a drag, and the derived path is the expensive part.
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds
                                                       cornerRadius:kTileCornerRadius].CGPath;
}

@end

#pragma mark - Grid

@interface GLMoreGridViewController ()
@property (nonatomic, strong) NSArray<GLMoreTileView *> *tiles;
/// Tiles in the order they are laid out. Rebuilt from the saved order at
/// load and mutated in place by a drag; the source of truth for layout.
@property (nonatomic, strong) NSMutableArray<GLMoreTileView *> *orderedTiles;
@property (nonatomic, strong) UILabel *headingLabel;
@property (nonatomic, strong) UIButton *doneButton;
@property (nonatomic, assign, getter=isEditingLayout) BOOL editingLayout;

// Drag state.
@property (nonatomic, weak) GLMoreTileView *draggingTile;
@property (nonatomic, assign) CGPoint dragStartPoint;
@property (nonatomic, assign) CGPoint dragTileStartCenter;
@property (nonatomic, assign) BOOL dragMoved;
@end

@implementation GLMoreGridViewController

- (instancetype)initWithModuleViewControllers:(NSArray<UIViewController *> *)moduleViewControllers {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;

    NSMutableArray<GLMoreTileView *> *tiles = [NSMutableArray array];
    for (UIViewController *vc in moduleViewControllers) {
        GLMoreTileView *tile = [[GLMoreTileView alloc] initWithFrame:CGRectZero];
        tile.moduleViewController = vc;
        // Falls back to the title so a module that somehow lacks a
        // restoration identifier still gets a stable-ish key rather than
        // nil, which would silently collapse every such tile onto one
        // dictionary slot.
        tile.identifier = vc.restorationIdentifier ?: vc.title;
        tile.titleLabel.text = vc.title;
        tile.iconView.image = vc.tabBarItem.image;
        [tiles addObject:tile];
    }
    _tiles = [tiles copy];

    self.title = @"More";
    self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"More"
                                                    image:[UIImage systemImageNamed:@"ellipsis"]
                                                      tag:0];
    return self;
}

#pragma mark - Saved arrangement

- (void)restoreArrangement {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray *savedOrder = [defaults arrayForKey:GLMoreGridOrderDefaultsName];
    NSArray *savedHeroes = [defaults arrayForKey:GLMoreGridHeroesDefaultsName];

    // Saved order first, in its own order; then any tile the saved list
    // doesn't mention, in module order, appended. That is what makes a NEWLY
    // ADDED module appear (at the end) instead of vanishing because it isn't
    // in a list written before it existed — and equally what makes a REMOVED
    // module's leftover entry harmless.
    NSMutableArray<GLMoreTileView *> *ordered = [NSMutableArray array];
    for (NSString *identifier in savedOrder) {
        if (![identifier isKindOfClass:[NSString class]]) continue;
        for (GLMoreTileView *tile in self.tiles) {
            if ([tile.identifier isEqualToString:identifier] && ![ordered containsObject:tile]) {
                [ordered addObject:tile];
                break;
            }
        }
    }
    for (GLMoreTileView *tile in self.tiles) {
        if (![ordered containsObject:tile]) [ordered addObject:tile];
    }
    self.orderedTiles = ordered;

    for (GLMoreTileView *tile in self.tiles) {
        tile.hero = [savedHeroes isKindOfClass:[NSArray class]] &&
                    [savedHeroes containsObject:tile.identifier];
    }
}

- (void)saveArrangement {
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    NSMutableArray<NSString *> *heroes = [NSMutableArray array];
    for (GLMoreTileView *tile in self.orderedTiles) {
        // -addObject: with nil raises. The identifier falls back to the
        // title, which is itself nullable, so guard rather than rely on the
        // registry always setting one.
        if (tile.identifier == nil) continue;
        [order addObject:tile.identifier];
        if (tile.isHero) [heroes addObject:tile.identifier];
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:order forKey:GLMoreGridOrderDefaultsName];
    [defaults setObject:heroes forKey:GLMoreGridHeroesDefaultsName];
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    [self restoreArrangement];

    _headingLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _headingLabel.text = @"More";
    _headingLabel.font = [UIFont systemFontOfSize:34 weight:UIFontWeightBold];
    [self.view addSubview:_headingLabel];

    _doneButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_doneButton setTitle:@"Done" forState:UIControlStateNormal];
    _doneButton.titleLabel.font = [GLTheme buttonFont];
    _doneButton.hidden = YES;
    [_doneButton addTarget:self action:@selector(endEditingLayout)
          forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_doneButton];

    for (GLMoreTileView *tile in self.tiles) {
        [self.view addSubview:tile];
        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
        [tile addGestureRecognizer:tap];
        UILongPressGestureRecognizer *press =
            [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handlePress:)];
        // Long enough not to fire on an ordinary tap-and-hold-a-beat, short
        // enough to feel like the home screen's own reorder gesture.
        press.minimumPressDuration = 0.45;
        // The finger WILL wander during a drag; the recognizer must not
        // cancel itself the moment it does.
        press.allowableMovement = CGFLOAT_MAX;
        [tile addGestureRecognizer:press];
        [tile.resizeBadge addTarget:self action:@selector(toggleHero:)
                   forControlEvents:UIControlEventTouchUpInside];
    }

    // Tapping anywhere that is not a tile also leaves edit mode — otherwise
    // the only way out is the Done button or a tile tap, and a tap on the
    // slack above the grid (which is most of the screen in edit mode) would
    // do nothing at all.
    UITapGestureRecognizer *backgroundTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleBackgroundTap:)];
    [self.view addGestureRecognizer:backgroundTap];

    [self applyTheme];
}

- (void)handleBackgroundTap:(UITapGestureRecognizer *)tap {
    if (self.isEditingLayout) [self endEditingLayout];
}

- (void)applyTheme {
    self.view.backgroundColor = [GLTheme backgroundColor];
    self.headingLabel.textColor = [GLTheme textPrimaryColor];
    self.doneButton.tintColor = [GLTheme accentColor];
    for (GLMoreTileView *tile in self.tiles) [tile applyTheme];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // The palette can change while this screen is off-screen (the theme is
    // fetched from the server, and Settings can switch it), and unlike the
    // web modules there is no reload here to pick it up.
    [self applyTheme];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // A drag runs its own spring animations as tiles trade places; an
    // unanimated relayout landing in the middle of one would snap every tile
    // to its final frame and undo the animation the user is watching.
    if (self.draggingTile != nil) return;
    [self layoutTilesAnimated:NO];
}

#pragma mark - Layout

// Rows, top to bottom, as arrays of tiles. A hero tile always occupies a row
// by itself; standard tiles pair up two per row.
//
// The INCOMPLETE row — the one holding a single standard tile when there is
// an odd number of them — is deliberately placed FIRST, at the top. The
// user: "i would want the singular one at the top not bottom since bottom is
// prime real estate". A lone centred tile at the bottom wastes half a row of
// the most reachable space on the screen; at the top it costs nothing,
// because the top of a phone screen is the hardest place to reach anyway.
//
// It is done by pretending one slot of the first row is already spoken for
// when the standard-tile count is odd, then packing greedily in order. Note
// this preserves READING order — the first tile in the user's arrangement is
// the one that ends up alone at the top, rather than the last tile being
// yanked up there, which is what moving a trailing short row would do.
- (NSArray<NSArray<GLMoreTileView *> *> *)rows {
    NSMutableArray<NSArray<GLMoreTileView *> *> *rows = [NSMutableArray array];
    NSUInteger index = 0;
    NSUInteger count = self.orderedTiles.count;

    while (index < count) {
        if (self.orderedTiles[index].isHero) {
            [rows addObject:@[ self.orderedTiles[index] ]];
            index++;
            continue;
        }
        // Parity is decided per RUN of consecutive standard tiles, not once
        // globally across the whole grid. A global count is wrong the moment
        // a hero sits between standard tiles: it decides the short row from
        // a total the hero has already broken into separate runs, and the
        // shortfall then surfaces wherever the arithmetic happens to land —
        // including the very last row. For [s1, hero, s2, s3, s4] a global
        // count is even, so no row is marked short, and the packing produces
        // a lone tile at the BOTTOM, which is the one thing this layout is
        // supposed to avoid.
        NSUInteger runStart = index;
        while (index < count && !self.orderedTiles[index].isHero) index++;
        NSUInteger runLength = index - runStart;

        NSUInteger cursor = runStart;
        if (runLength % 2 == 1) {
            // The odd tile goes FIRST within its run — highest on screen —
            // and reading order is preserved, unlike moving a trailing short
            // row up, which would yank the run's LAST tile to the top.
            [rows addObject:@[ self.orderedTiles[cursor] ]];
            cursor++;
        }
        for (; cursor + 1 < runStart + runLength; cursor += 2) {
            [rows addObject:@[ self.orderedTiles[cursor], self.orderedTiles[cursor + 1] ]];
        }
    }
    return rows;
}

- (void)layoutTilesAnimated:(BOOL)animated {
    NSArray<NSArray<GLMoreTileView *> *> *rows = [self rows];
    if (rows.count == 0) return;

    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat margin = [GLTheme spacingM];
    CGFloat gutter = [GLTheme spacingS];
    CGFloat left = safe.left + margin;
    CGFloat contentWidth = self.view.bounds.size.width - safe.left - safe.right - 2 * margin;

    // The heading occupies the slack above the grid rather than pushing the
    // grid down: it is drawn in whatever room is left over, and if there is
    // no room left over it is hidden instead of squeezing the tiles.
    CGFloat headingHeight = 44.0;
    CGFloat topLimit = safe.top + margin;
    CGFloat bottomLimit = self.view.bounds.size.height - safe.bottom - margin;
    CGFloat availableHeight = bottomLimit - topLimit - headingHeight - gutter;

    // Two sizes: the largest square that fits two-across, and the largest
    // that lets every row fit vertically. The SMALLER wins, which is what
    // makes "not bigger than the total page" true by construction rather
    // than by hoping the row count stays at three.
    CGFloat sideFromWidth = floor((contentWidth - gutter) / 2.0);
    CGFloat sideFromHeight = floor((availableHeight - (rows.count - 1) * gutter) / rows.count);
    CGFloat side = MIN(sideFromWidth, sideFromHeight);
    if (side < 1) return;

    CGFloat gridHeight = rows.count * side + (rows.count - 1) * gutter;
    // Bottom-anchored: every pixel of slack goes ABOVE the grid, so the
    // tiles sit in the reachable half of the screen. This is the same goal
    // the old table's bottom inset had — the difference is that this leaves
    // the slack usable (the heading lives in it) instead of empty, and it
    // stops at the tab bar instead of running underneath it, because
    // `bottomLimit` is derived from the safe area the tab bar defines.
    CGFloat gridTop = bottomLimit - gridHeight;

    void (^apply)(void) = ^{
        CGFloat y = gridTop;
        for (NSArray<GLMoreTileView *> *row in rows) {
            if (row.count == 1 && !row.firstObject.isHero) {
                // The lone standard tile: centred, and the SAME size as
                // every other tile rather than stretched to fill the row.
                GLMoreTileView *tile = row.firstObject;
                if (tile != self.draggingTile) {
                    tile.frame = CGRectMake(left + floor((contentWidth - side) / 2.0), y, side, side);
                }
            } else if (row.count == 1 && row.firstObject.isHero) {
                GLMoreTileView *tile = row.firstObject;
                if (tile != self.draggingTile) {
                    tile.frame = CGRectMake(left, y, contentWidth, side);
                }
            } else {
                for (NSUInteger i = 0; i < row.count; i++) {
                    GLMoreTileView *tile = row[i];
                    if (tile == self.draggingTile) continue;
                    tile.frame = CGRectMake(left + i * (side + gutter), y, side, side);
                }
            }
            y += side + gutter;
        }

        // Pinned to the TOP of the available area, not floated just above
        // the grid. The tiles are square and width-limited, so with three
        // rows there is always vertical slack; putting the heading at the
        // top makes that slack read as an iOS large-title header with
        // breathing room under it, rather than as a void above a stray
        // label. It falls back to sitting just above the grid only if the
        // grid ever grows tall enough to reach the top.
        CGFloat headingY = topLimit;
        if (headingY + headingHeight + gutter > gridTop) {
            headingY = gridTop - gutter - headingHeight;
        }
        self.headingLabel.frame = CGRectMake(left, headingY, contentWidth / 2.0, headingHeight);
        CGFloat headingAlpha = (headingY >= topLimit) ? 1.0 : 0.0;
        self.headingLabel.alpha = headingAlpha;
        self.doneButton.frame = CGRectMake(left + contentWidth / 2.0, headingY,
                                           contentWidth / 2.0, headingHeight);
        // Fades with the heading it shares a line with — otherwise a
        // height-crunched layout hides the heading and leaves Done floating
        // alone up in the status bar.
        self.doneButton.alpha = headingAlpha;
    };

    if (animated) {
        [UIView animateWithDuration:0.25
                              delay:0
             usingSpringWithDamping:0.85
              initialSpringVelocity:0
                            options:UIViewAnimationOptionBeginFromCurrentState
                         animations:apply
                         completion:nil];
    } else {
        apply();
    }
}

#pragma mark - Opening a module

- (void)handleTap:(UITapGestureRecognizer *)tap {
    GLMoreTileView *tile = (GLMoreTileView *)tap.view;
    if (self.isEditingLayout) {
        // In edit mode a tap is not "open this" — it is how you leave edit
        // mode, matching the home screen. Opening a module here would make
        // every mis-aimed rearrange navigate away.
        [self endEditingLayout];
        return;
    }
    [self openModuleViewController:tile.moduleViewController];
}

/// Shared by the tile tap and the UITEST_MORE_TILE hook below, so the test
/// path and the real path are the same code.
- (void)openModuleViewController:(UIViewController *)module {
    if (module == nil) return;

    // A module that wraps itself in its own UINavigationController (Journal
    // does, so it can push its "Recent" screen) must NOT be pushed:
    // -pushViewController: raises NSInvalidArgumentException, "Pushing a
    // navigation controller is not supported". UIKit's own More list never
    // pushed one either — it SELECTED it, which is also what
    // AutoJournalViewController's -selectJournalTab and SceneDelegate's
    // UITEST_TAB hook do, and the path CI has been screenshotting all along.
    // Doing the same here keeps the wrapper intact, so Journal's own
    // navigation bar and its Recent screen still work.
    if ([module isKindOfClass:[UINavigationController class]]) {
        UITabBarController *tabs = self.tabBarController;
        if (tabs != nil && [tabs.viewControllers containsObject:module]) {
            tabs.selectedViewController = module;
        }
        return;
    }

    if (self.navigationController == nil) return;
    // Everything else is pushed onto the More navigation controller — exactly
    // the controller and the stack UIKit's own list used, so the hidden
    // navigation bar and the back-swipe behave as they did before.
    [self.navigationController pushViewController:module animated:YES];
}

/// Test hook: open a tile by its module restoration identifier, driving the
/// same code a tap does. Returns NO if no tile matches.
- (BOOL)openModuleWithIdentifier:(NSString *)identifier {
    for (GLMoreTileView *tile in self.tiles) {
        if ([tile.identifier isEqualToString:identifier]) {
            [self openModuleViewController:tile.moduleViewController];
            return YES;
        }
    }
    return NO;
}

#pragma mark - Edit mode

- (void)beginEditingLayout {
    if (self.isEditingLayout) return;
    self.editingLayout = YES;
    self.doneButton.hidden = NO;
    for (GLMoreTileView *tile in self.tiles) tile.resizeBadge.hidden = NO;
}

- (void)endEditingLayout {
    if (!self.isEditingLayout) return;
    self.editingLayout = NO;
    self.doneButton.hidden = YES;
    for (GLMoreTileView *tile in self.tiles) tile.resizeBadge.hidden = YES;
    [self saveArrangement];
}

- (void)toggleHero:(UIButton *)sender {
    GLMoreTileView *tile = (GLMoreTileView *)sender.superview;
    if (![tile isKindOfClass:[GLMoreTileView class]]) return;
    tile.hero = !tile.isHero;
    [self layoutTilesAnimated:YES];
    [self saveArrangement];
}

#pragma mark - Drag to rearrange

- (void)handlePress:(UILongPressGestureRecognizer *)press {
    GLMoreTileView *tile = (GLMoreTileView *)press.view;
    CGPoint point = [press locationInView:self.view];

    switch (press.state) {
        case UIGestureRecognizerStateBegan: {
            [self beginEditingLayout];
            self.draggingTile = tile;
            self.dragStartPoint = point;
            self.dragTileStartCenter = tile.center;
            self.dragMoved = NO;
            [self.view bringSubviewToFront:tile];
            [UIView animateWithDuration:0.18 animations:^{
                tile.transform = CGAffineTransformMakeScale(1.06, 1.06);
                tile.layer.shadowOpacity = 0.4;
            }];
            break;
        }
        case UIGestureRecognizerStateChanged: {
            if (self.draggingTile != tile) return;
            CGFloat dx = point.x - self.dragStartPoint.x;
            CGFloat dy = point.y - self.dragStartPoint.y;
            if (!self.dragMoved && (fabs(dx) + fabs(dy)) < kDragSlop) return;
            self.dragMoved = YES;
            tile.center = CGPointMake(self.dragTileStartCenter.x + dx,
                                      self.dragTileStartCenter.y + dy);

            NSUInteger from = [self.orderedTiles indexOfObject:tile];
            NSUInteger to = [self insertionIndexForDraggedTile:tile];
            if (from != NSNotFound && to != NSNotFound && to != from) {
                [self.orderedTiles removeObjectAtIndex:from];
                [self.orderedTiles insertObject:tile atIndex:to];
                [self layoutTilesAnimated:YES];
            }
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            if (self.draggingTile != tile) return;
            self.draggingTile = nil;
            [UIView animateWithDuration:0.2 animations:^{
                tile.transform = CGAffineTransformIdentity;
                tile.layer.shadowOpacity = 0.18;
            }];
            // Settle the dragged tile into its slot along with everything
            // else, now that it is no longer excluded from layout.
            [self layoutTilesAnimated:YES];
            [self saveArrangement];
            break;
        }
        default:
            break;
    }
}

// Which index the dragged tile should occupy, judged by its CENTRE against
// the centres of the other tiles' current (settled) frames. Comparing centres
// rather than testing for overlap means the answer is defined everywhere on
// the screen — including the gaps between tiles and the empty slack above
// the grid, where an overlap test returns nothing and the tile would stick
// to a stale index.
- (NSUInteger)insertionIndexForDraggedTile:(GLMoreTileView *)dragged {
    CGPoint center = dragged.center;
    NSUInteger current = [self.orderedTiles indexOfObject:dragged];
    NSUInteger best = current;
    CGFloat bestDistance = CGFLOAT_MAX;
    CGFloat nearestSide = dragged.bounds.size.height;
    for (NSUInteger i = 0; i < self.orderedTiles.count; i++) {
        GLMoreTileView *tile = self.orderedTiles[i];
        if (tile == dragged) continue;
        CGFloat dx = tile.center.x - center.x;
        CGFloat dy = tile.center.y - center.y;
        CGFloat distance = dx * dx + dy * dy;
        if (distance < bestDistance) {
            bestDistance = distance;
            best = i;
            nearestSide = MIN(tile.bounds.size.width, tile.bounds.size.height);
        }
    }
    // Only commit to a swap once the dragged tile is genuinely OVER its new
    // neighbour — within half a tile of that neighbour's centre. Reordering
    // on "nearest" alone makes the grid oscillate: the swap moves the other
    // tile under the finger, which immediately makes the ORIGINAL slot the
    // nearest again, and the two trade places every frame.
    CGFloat commitRadius = nearestSide / 2.0;
    if (bestDistance > commitRadius * commitRadius) return current;
    return best;
}

@end
