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

### Optional hooks: fan-out from the app shell

The app shell (`AppDelegate.m` / `SceneDelegate.m`) contains **zero**
feature-specific knowledge — it doesn't import `GLManager.h`, `CoreLocation`,
or any module header, and it doesn't know what any URL scheme, quick-action
type, or `NSUserActivity` type means. Instead it fans out generically to
every module via five `@optional` methods on `GLModule`:

```objc
+ (void)moduleDidFinishLaunchingWithOptions:(nullable NSDictionary *)launchOptions;  // app launch, once
+ (BOOL)moduleHandleURL:(NSURL *)url;                                // return YES if consumed
+ (BOOL)moduleHandleUserActivity:(NSUserActivity *)activity;         // return YES if consumed
+ (BOOL)moduleHandleShortcutItem:(UIApplicationShortcutItem *)item;  // return YES if consumed
+ (NSString *)moduleDiagnosticSummary;                               // lines for the launch diagnostic alert, or nil
```

`moduleDidFinishLaunchingWithOptions:` receives UIKit's real launch-options
dictionary unmodified — the shell attaches no meaning to any key in it
(including `UIApplicationLaunchOptionsLocationKey`, a background-location
relaunch signal only a location module cares about). Likewise
`moduleHandleUserActivity:` and `moduleHandleShortcutItem:` receive the real
`NSUserActivity` / `UIApplicationShortcutItem` UIKit handed the shell — never
a synthetic stand-in constructed by the shell to signal something else.
**A module MUST return `NO` from `moduleHandleUserActivity:` and
`moduleHandleShortcutItem:` for any activity/item type it does not own**, so
the registry can offer it to the next module; returning `YES` (or mutating
shared state) for an unrecognized type is a bug, not permissive handling.

`GLModuleRegistry` exposes the matching fan-out, walking the same
`+moduleClasses` list tab installation uses (cached via `dispatch_once` since
module membership can't change at runtime), and guarding every call with
`respondsToSelector:` since the hooks are optional:

```objc
+ (void)notifyModulesDidFinishLaunchingWithOptions:(nullable NSDictionary *)launchOptions;
+ (BOOL)routeURL:(NSURL *)url;                 // first module returning YES wins
+ (BOOL)routeUserActivity:(NSUserActivity *)activity;
+ (BOOL)routeShortcutItem:(UIApplicationShortcutItem *)item;
+ (NSString *)diagnosticSummary;               // joins each module's summary, skipping nil/empty
```

The launch fan-out logs which modules responded (`Module registry: launch
hooks fired for N modules: ...`), the same way tab installation logs which
tabs it installed — `sim-test.yml` asserts on both lines, so a hook renamed
out from under `respondsToSelector:` fails CI instead of silently going dead.

If your module needs to run setup at launch, handle a custom-scheme URL, a
Siri/Handoff continuation, or a home-screen quick action, or contribute a
line to the build diagnostic, implement the relevant method(s) — don't touch
the shell. For lifecycle events that already have a real UIKit notification
(foreground/background/resign-active/terminate), observe the notification
yourself from inside your module rather than asking the shell to call you —
see `Modules/Tracker/TrackerAppLifecycle.m`'s `+load` for the pattern.

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
- **Never** edit another module's directory, `GLModuleRegistry.{h,m}`,
  `GLModule.h`, `AppDelegate.m`, `SceneDelegate.m`, or
  `Overland.xcodeproj/project.pbxproj`. These five are the shared contract
  and the shell — a module session touching them can break every other
  module or race a concurrent session editing the same file. Everything an
  ordinary module needs is reachable through the optional-hook fan-out above
  (implement `+moduleDidFinishLaunchingWithOptions:` / `+moduleHandleURL:` /
  `+moduleHandleUserActivity:` / `+moduleHandleShortcutItem:` /
  `+moduleDiagnosticSummary` in your own module class, or observe a UIKit
  notification yourself) — that is the
  extension point, not editing the shell. A session that finds it genuinely
  needs a new shell hook should propose extending `GLModule.h` /
  `GLModuleRegistry` explicitly, the way this one did, rather than reaching
  into `AppDelegate.m` / `SceneDelegate.m` directly.
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

## CI budget

macOS GitHub Actions runners bill at **10x** normal minutes. The free tier is
~200 macOS minutes/month — that's it, no more.

- `ota` is the default delivery path. It runs automatically on every push to
  `main`, builds an ad-hoc ipa, and a poller on the dev box installs it
  (~1 min, no ASC processing). Don't add anything else to its auto-trigger.
- `build` (TestFlight) is **manual only** (`workflow_dispatch`). Dispatch it
  by hand only when the phone is off the tailnet and OTA can't reach it.
- `sim-test` is **manual only**. It is opt-in — dispatch it when there is an
  actual visual/behavioral claim to verify, not reflexively. Batch: one run
  per change, never one run per question.
- `gen-project` and `device-farm-build` are already manual-only; keep them
  that way.
- Agents must not use CI as a compiler. Don't push or dispatch a workflow to
  "see if it builds" — read the code, use `xcodebuild` locally if available,
  or ask.
- Before dispatching any workflow, run `gh run list` and check for an
  in-flight run of the same workflow first. Don't queue a duplicate.
- Every workflow carries a `concurrency` group keyed on
  `${{ github.workflow }}-${{ github.ref }}` with `cancel-in-progress: true`,
  so rapid successive pushes cancel the stale run instead of stacking minutes.
  Don't remove it.
- `ota.yml`'s `paths-ignore` keeps doc/tooling-only changes from triggering a
  macOS build. When adding a new ignored path, confirm it truly can't affect
  the built product — when in doubt, don't ignore it.

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

The run also asserts on the registry's launch log lines:

```
Module registry: installed N tabs: Tracker, Settings, Upload
Module registry: launch hooks fired for N modules: Tracker
```

Bump `N` and the title list for the tabs line when your tab is added; bump
the launch-hooks line only if your module implements
`moduleDidFinishLaunchingWithOptions:`.

## Getting a build onto the phone

Pushing to `main` triggers exactly one workflow:

- **`ota`** — ad-hoc ipa, published to the OTA install page at
  <https://wsl-esme-1.tailc6cd5d.ts.net:10000/>. Reaches the phone within
  ~2 minutes of the push. This is the default delivery path.

**`build`** (signed archive → TestFlight) is `workflow_dispatch`-only. Dispatch
it by hand only when the phone is off the tailnet and OTA can't reach it — see
the CI budget section above.

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
#   #import "BakedConfig.h"      (GL_BAKED_BASE_URL / GL_BAKED_TOKEN)
#   #import "GLEndpoints.h"      (GLEndpointURL(path) — build a full URL)
#   #import "GLDropUploader.h"   (POST helper)

# Append an Events screenshot step to .github/workflows/sim-test.yml
# (tab index 3) and bump the "installed 4 tabs" assertion.

git add -A && git commit -m "Add the Events micro app"
git push -u origin events
gh workflow run sim-test --ref events

# Poll, download main-screen artifact, LOOK at events-screen.png and
# main-screen.png (tab bar must read Tracker | Settings | Upload | Events).

git checkout main && git merge events && git push
# Watch `ota` go green (the only workflow the push triggers), then check the
# OTA page picked up the new build number.
```

Total files touched outside `Modules/Events/`: one — `sim-test.yml`. Two
sessions appending different screenshot steps to it conflict only on adjacent
lines; take both hunks.
