# Overland-iOS — project instructions

## BLOCKING: Read the CI budget rules before touching CI or workflows

Before pushing to `main`, dispatching a workflow, or editing anything under
`.github/workflows/`, read the **CI budget** section in `MODULES.md`. macOS
runners bill at 10x and the free tier is small — CI spend has already blown
through the free tier once. `ota` auto-runs on push; `build` (TestFlight) and
`sim-test` are manual-only and must not be re-added to a push trigger without
a deliberate reason.

## MANDATORY: Probe framework behavior before asserting on it

CI is the only compiler, and each round costs ~10 minutes. Never write an
assertion that depends on an unverified guess about how an Apple framework
behaves (what types an `NSItemProvider` registers, what it names a vended
file, how it wraps errors, UIKit layout).

- **Probe first.** When tests depend on framework behavior, the first dispatch
  is a probe test that logs the real behavior for every input shape you plan
  to test and asserts nothing about it. Write the assertions from that output.
- **Failure messages name the cause.** Every error path reports the underlying
  `NSError`, the class it actually received, and which branch failed. A
  generic "could not read file" wastes a round.
- **One fix round per run.** Fix every failure from a run in one commit. Never
  add new premise-dependent tests to a fix round without probing them too.
