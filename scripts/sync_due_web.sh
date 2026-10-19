#!/usr/bin/env bash
# Copies the built Due Clone web UI (due-clone/web/dist) into DueApp/Web, the folder the app bundles and serves offline.
# Usage: scripts/sync_due_web.sh [path/to/due-clone]   (default ~/coding/due-clone)
set -euo pipefail
SRC="${1:-$HOME/coding/due-clone}/web/dist"
test -f "$SRC/index.html" || { echo "no build at $SRC (run: cd web && npx vite build)"; exit 1; }
DEST="$(cd "$(dirname "$0")/.." && pwd)/DueApp/Web"
rm -rf "$DEST" && cp -R "$SRC" "$DEST"
echo "synced $SRC -> $DEST"
