#!/usr/bin/env bash
# Verifies design-tokens/native-theme.json (committed IN THIS REPO) still
# matches the generator's real output in the `assistant` repo.
#
# Why a committed copy at all, instead of sim-test.yml checking out the
# generator directly: `assistant` is a PRIVATE repo and sim-test.yml never
# checks it out (see that workflow's own comment above where it reads this
# file). A copy that lives here is the only palette source sim-test.yml can
# reach without adding a cross-repo checkout + PAT to a CI job whose whole
# point is to be cheap and disposable (see MODULES.md's CI-budget section).
#
# What this guards against: this copy going stale exactly the way the
# DUSK_LIGHT/DUSK_DARK shell literals it replaced went stale -- a key gets
# added to native-theme.json (surface-translucent/backdrop-blur did, once)
# and nobody remembers to re-sync the copy in THIS repo. This script is the
# manual (not CI-wired, since CI can't see the private repo either) check a
# person or an agent runs before/after touching either repo's theme code.
#
# Usage: scripts/check_palette_sync.sh [path-to-assistant-repo-checkout]
# Defaults to ../assistant relative to this repo's root (the layout this
# box actually uses -- both repos live under ~/coding/assistant/).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMITTED="$REPO_ROOT/design-tokens/native-theme.json"

ASSISTANT_REPO="${1:-$REPO_ROOT/..}"
SOURCE="$ASSISTANT_REPO/design-tokens/native-theme.json"

if [ ! -f "$COMMITTED" ]; then
  echo "FATAL: $COMMITTED does not exist -- nothing to check against the generator" >&2
  exit 1
fi
if [ ! -f "$SOURCE" ]; then
  echo "FATAL: no design-tokens/native-theme.json found under '$ASSISTANT_REPO'." >&2
  echo "Pass the assistant repo checkout path as an argument, e.g.:" >&2
  echo "  scripts/check_palette_sync.sh ~/coding/assistant" >&2
  exit 1
fi

if diff -u "$SOURCE" "$COMMITTED"; then
  echo "OK: $COMMITTED matches the generator's output at $SOURCE"
  exit 0
else
  echo "MISS: $COMMITTED has drifted from the generator's output at $SOURCE (diff above)." >&2
  echo "Re-run: cp '$SOURCE' '$COMMITTED' && git -C '$REPO_ROOT' add design-tokens/native-theme.json" >&2
  exit 1
fi
