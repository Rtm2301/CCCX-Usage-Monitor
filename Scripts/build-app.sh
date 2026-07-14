#!/bin/bash
# Builds UsageBar.app with plain swiftc (no SPM — the CLT on this machine has a
# broken PackageDescription; there are no external dependencies anyway).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/CCCX Usage Monitor.app"
BIN=dist/UsageBar

mkdir -p dist
echo "Compiling..."
swiftc -parse-as-library -O \
  -target arm64-apple-macos14.0 \
  $(find Sources/UsageBar -name '*.swift') \
  -o "$BIN"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BIN" "$APP/Contents/MacOS/UsageBar"
cp Support/Info.plist "$APP/Contents/"
# App icon (generated via Scripts/make-icon.sh from icon.png)
if [ -f Support/UsageBar.icns ]; then
  cp Support/UsageBar.icns "$APP/Contents/Resources/"
fi
codesign --force --sign - "$APP"
echo "Built $APP"

# --install: copy to /Applications
if [ "${1:-}" = "--install" ]; then
  pkill -f "MacOS/UsageBar" 2>/dev/null || true
  rm -rf /Applications/UsageBar.app "/Applications/Usage CCCX.app" "/Applications/CCCX Usage Monitor.app"
  cp -R "$APP" /Applications/
  echo "Installed /Applications/CCCX Usage Monitor.app"
  echo "Run: open '/Applications/CCCX Usage Monitor.app'"
else
  echo "Run: open '$APP'   (or Scripts/build-app.sh --install)"
fi
