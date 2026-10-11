#!/bin/sh
# Generates the project, builds for the connected iPhone, installs and launches. Optional arg: device UDID.
set -e
cd "$(dirname "$0")"
DEVICE="${1:-$(xcrun devicectl list devices | grep -E 'physical' | grep -E 'available' | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1)}"
[ -n "$DEVICE" ] || { echo "no connected iPhone" >&2; exit 1; }
xcodegen generate --quiet
lease --class build -- xcodebuild build -project RenderProbe.xcodeproj -scheme RenderProbe -destination "id=$DEVICE" \
  -derivedDataPath build -allowProvisioningUpdates -quiet
xcrun devicectl device install app --device "$DEVICE" build/Build/Products/Debug-iphoneos/RenderProbe.app
xcrun devicectl device process launch --device "$DEVICE" com.simplecityapps.renderprobe
