#!/usr/bin/env bash
# Fails when code outside the navigation owners switches tabs directly.
#
# Every module brings itself (or another module) on screen through
# +[GLModuleRegistry showModuleWithIdentifier:]. That one call knows the
# visible-tab vs More-overflow split, and it counts as an explicit
# navigation, so a lock-screen deep link always beats the default-tab
# reset on resume (Modules/GLDefaultTabArbiter.h). A direct
# `selectedIndex =` / `selectedViewController =` skips both, which is how
# the Journal voice Control ended up recording on the wrong tab after
# Journal moved into More.
#
# Allowed: the registry itself, SceneDelegate's UITEST_* hooks, and the
# legacy GLMoreGridViewController (no longer instantiated).
set -euo pipefail
cd "$(dirname "$0")/.."

hits=$(grep -rnE '\.selected(Index|ViewController)[[:space:]]*=[^=]|setSelected(Index|ViewController):' \
         --include='*.m' --include='*.swift' App Modules Shared JournalControl ShareToDesktop \
       | grep -vE '^(Modules/GLModuleRegistry\.m|App/SceneDelegate\.m|Modules/More/GLMoreGridViewController\.m):' \
       || true)

if [ -n "$hits" ]; then
  echo "Direct tab selection outside GLModuleRegistry:"
  echo "$hits"
  echo "Use [GLModuleRegistry showModuleWithIdentifier:@\"GLModule.<ModuleClass>\"] instead."
  exit 1
fi
echo "OK: no direct tab selection outside GLModuleRegistry"
