# MODULES

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
