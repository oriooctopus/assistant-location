#!/bin/bash
# Prints Listen's native build stamp: the commit time of the last change to anything that ends up in the Listen binary.
# ota-listen.yml writes it into Info.plist as ListenNativeVersion, and the box reports the one on the published ipa as
# GET /api/native, so a phone with an older stamp shows the "New version" bar.
# ListenApp bundles no web files (the page is served by the box), so unlike Cycle nothing is excluded from ListenApp.
# Needs full git history (checkout with fetch-depth: 0). This list is the ONE place that decides what counts as native.
set -euo pipefail
cd "$(dirname "$0")/.."
stamp="$(git log -1 --format=%ct -- ListenApp ListenControl Shared/GLLog.h Shared/GLOfflineShell.h Shared/GLOfflineShell.m Overland.xcodeproj/project.pbxproj scripts/add_listen_app.rb scripts/add_listen_control_ext.rb scripts/add_listen_icon.rb fastlane)"
test -n "$stamp" || { echo "listen-native-version: no native commit found (shallow clone?)" >&2; exit 1; }
echo "$stamp"
