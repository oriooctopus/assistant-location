#!/usr/bin/env bash
# Scaffold a new micro app (one tab).
#
#   scripts/new_module.sh Events [order]
#
# Writes Modules/<Name>/<Name>Module.{h,m} plus a stub view controller and
# nothing else — no project.pbxproj edit, no storyboard edit, no registry edit.
# Modules/ is a file-system-synchronized folder, so the new files are compiled
# and the new tab appears on the next build.
set -euo pipefail

NAME="${1:-}"
if [[ -z "$NAME" ]]; then
    echo "usage: scripts/new_module.sh <Name> [order]" >&2
    exit 1
fi
if ! [[ "$NAME" =~ ^[A-Z][A-Za-z0-9]*$ ]]; then
    echo "module name must be UpperCamelCase (letters and digits): got '$NAME'" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$ROOT/Modules/$NAME"
if [[ -e "$DIR" ]]; then
    echo "$DIR already exists — pick another name or delete it first" >&2
    exit 1
fi

# Default order: 100 past the highest already declared, so a fresh module lands
# at the right-hand end of the tab bar and never collides with an existing one.
if [[ -n "${2:-}" ]]; then
    ORDER="$2"
else
    HIGHEST=$(grep -rhoE '\+ *\( *NSInteger *\) *moduleOrder *\{ *return *(-?[0-9]+)' \
                  "$ROOT/Modules" 2>/dev/null | grep -oE -- '-?[0-9]+$' | sort -n | tail -1 || true)
    ORDER=$(( ${HIGHEST:-0} + 100 ))
fi

mkdir -p "$DIR"

cat > "$DIR/${NAME}Module.h" <<EOF
// $NAME micro app. See MODULES.md at the repo root.

#import <Foundation/Foundation.h>
#import "GLModule.h"

@interface ${NAME}Module : NSObject <GLModule>
@end
EOF

cat > "$DIR/${NAME}Module.m" <<EOF
#import "${NAME}Module.h"

#import "${NAME}ViewController.h"

@implementation ${NAME}Module

+ (NSString *)moduleTitle { return @"$NAME"; }

+ (UIImage *)moduleIcon { return [UIImage systemImageNamed:@"square.grid.2x2"]; }

+ (NSInteger)moduleOrder { return $ORDER; }

+ (UIViewController *)makeViewController {
    return [[${NAME}ViewController alloc] init];
}

@end
EOF

cat > "$DIR/${NAME}ViewController.h" <<EOF
#import <UIKit/UIKit.h>

@interface ${NAME}ViewController : UIViewController
@end
EOF

cat > "$DIR/${NAME}ViewController.m" <<EOF
#import "${NAME}ViewController.h"

@implementation ${NAME}ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UILabel *label = [[UILabel alloc] init];
    label.text = @"$NAME";
    label.font = [UIFont boldSystemFontOfSize:22];
    label.textAlignment = NSTextAlignmentCenter;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];
}

@end
EOF

echo "Created Modules/$NAME (order $ORDER):"
ls "$DIR" | sed 's/^/  Modules\/'"$NAME"'\//'
echo
echo "Nothing else was touched — 'git status' should show only Modules/$NAME/."
echo "Next: gh workflow run sim-test --ref \$(git branch --show-current)"
