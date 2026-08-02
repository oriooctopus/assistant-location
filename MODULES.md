# Adding a micro app (tab)

Read this before writing any code. The app is a shell; each tab is an
independent **module** under `Modules/`. Several sessions can add tabs at the
same time because a module shares **no file** with any other module.

## The contract

`Modules/GLModule.h`:

```objc
@protocol GLModule <NSObject>
+ (NSString *)moduleTitle;        // tab bar title
+ (UIImage *)moduleIcon;          // e.g. [UIImage systemImageNamed:@"calendar"]
+ (NSInteger)moduleOrder;         // lower sorts left; ties break on class name
+ (UIViewController *)makeViewController;   // fresh root VC for the tab
@end
```

`GLModuleRegistry` walks the ObjC runtime at launch (`objc_copyClassList` +
`class_conformsToProtocol`), sorts the conformers, calls `+makeViewController`
on each, and sets `title` / `tabBarItem` / `restorationIdentifier` on the
result. **Do not set your own `tabBarItem`** — the registry owns it.

Orders in use: Tracker 100, Settings 200, Upload 300. Pick an unused value;
`new_module.sh` defaults to highest + 100.

## Where files go

```
Modules/<Name>/          ← yours, exclusively. Nothing else may live here.
Modules/GLModule.h       ← the contract (do not edit)
Modules/GLModuleRegistry.{h,m}  ← discovery (do not edit)
Shared/, GPSLogger/      ← shared code: GLManager, GLDropUploader, BakedConfig.
                           You may IMPORT these; do not restructure them.
```

`Modules/` is a **file-system-synchronized folder** (`objectVersion = 77`,
`PBXFileSystemSynchronizedRootGroup`). Every `.m` you drop under it is compiled
automatically — **there is no `project.pbxproj` edit**, which is why concurrent
branches merge cleanly.

`HEADER_SEARCH_PATHS` covers `Modules/`, `GPSLogger/` and `Shared/`, so import
by bare name: `#import "GLManager.h"`, `#import "GLDropUploader.h"`,
`#import "BakedConfig.h"`.

### Rules

- **Never** edit `GPSLogger/Base.lproj/Main.storyboard`. Build your UI in code.
- **Never** edit another module's directory, `GLModuleRegistry.m`, `GLModule.h`,
  `SceneDelegate.m`, or `Overland.xcodeproj/project.pbxproj`.
- **Never** import another module's headers. Modules depend on `Shared/` and
  `GPSLogger/` only, never on each other.
- No defensive fallbacks. If a shared invariant is violated, raise.

## Worktree convention

```bash
cd ~/coding/assistant/Overland-iOS
git worktree add .claude/worktrees/<module-name> -b <module-name> main
```

One worktree per module, always branched off `main`.

## Scaffolding

```bash
scripts/new_module.sh Events          # → Modules/Events/, order = highest+100
scripts/new_module.sh Events 500      # explicit order
```

Produces a compiling app with a new tab showing a centred label. `git status`
after running it shows **only** `Modules/Events/`.

## CI and verification

```bash
gh workflow run sim-test --ref <branch>              # build + boot in simulator
gh run list --branch <branch> --limit 1              # poll to completion
gh run download <run-id> -n main-screen -D /tmp/shots
```

`sim-test` builds for the simulator, boots the app, drives location, and
screenshots each tab. Select a tab with `SIMCTL_CHILD_UITEST_TAB=<index>`
(read by `SceneDelegate`). **Add a screenshot step for your tab's index** in
`.github/workflows/sim-test.yml` — that file is the one shared file a module
session may touch, and only to append its own screenshot + artifact path.

Verification means **looking at the pixels** in the downloaded PNGs: your tab
renders its content, and the tab bar shows every module's title in order. A
green run alone is not verification.

The run also asserts on the registry's launch log line:

```
Module registry: installed N tabs: Tracker, Settings, Upload
```

Bump `N` and the title list in `sim-test.yml` when your tab is added.

## Getting a build onto the phone

Pushing to `main` triggers two workflows:

- **`ota`** — ad-hoc ipa, published to the OTA install page at
  <https://wsl-esme-1.tailc6cd5d.ts.net:10000/>. Reaches the phone within
  ~2 minutes of the push. This is the fast path.
- **`build`** — signed archive uploaded to TestFlight.

### TestFlight delivery is verified via the ASC API, never a CI log line

A green `build` run means "uploaded", not "installable". Processing can still
fail silently afterwards. Confirm with App Store Connect:

```bash
python3 ~/.config/assistant/asc.py GET \
  "/v1/builds?filter[app]=<APP_ID>&limit=1&include=betaGroups&fields[builds]=version,processingState"
```

A build is delivered only when it has `betaGroups` containing `Internal` **and**
`internalBuildState = IN_BETA_TESTING`. Anything else — including
`PROCESSING`, `READY_FOR_BETA_SUBMISSION`, or an empty `betaGroups` — is not
delivered, and reporting it as delivered is a false PASS.

## Worked example: adding an Events tab

```bash
cd ~/coding/assistant/Overland-iOS
git worktree add .claude/worktrees/events -b events main
cd .claude/worktrees/events

scripts/new_module.sh Events
# → Modules/Events/EventsModule.{h,m}, Modules/Events/EventsViewController.{h,m}

# Build the real UI in EventsViewController.m. Import shared code by name:
#   #import "GLManager.h"        (location state)
#   #import "BakedConfig.h"      (GL_BAKED_ENDPOINT / GL_BAKED_TOKEN)
#   #import "GLDropUploader.h"   (POST helper)

# Append an Events screenshot step to .github/workflows/sim-test.yml
# (tab index 3) and bump the "installed 4 tabs" assertion.

git add -A && git commit -m "Add the Events micro app"
git push -u origin events
gh workflow run sim-test --ref events

# Poll, download main-screen artifact, LOOK at events-screen.png and
# main-screen.png (tab bar must read Tracker | Settings | Upload | Events).

git checkout main && git merge events && git push
# Watch `build` + `ota` go green, then verify TestFlight delivery via asc.py
# and check the OTA page picked up the new build.
```

Total files touched outside `Modules/Events/`: one — `sim-test.yml`. Two
sessions appending different screenshot steps to it conflict only on adjacent
lines; take both hunks.
