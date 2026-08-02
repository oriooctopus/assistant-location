# Overland-iOS — project instructions

## BLOCKING: Read the CI budget rules before touching CI or workflows

Before pushing to `main`, dispatching a workflow, or editing anything under
`.github/workflows/`, read the **CI budget** section in `MODULES.md`. macOS
runners bill at 10x and the free tier is small — CI spend has already blown
through the free tier once. `ota` auto-runs on push; `build` (TestFlight) and
`sim-test` are manual-only and must not be re-added to a push trigger without
a deliberate reason.
