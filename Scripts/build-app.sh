#!/bin/bash
# Builds "CCCX Usage Monitor.app" with plain swiftc (no SPM; zero dependencies).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/CCCX Usage Monitor.app"
BIN=dist/CCCXUsageMonitor

mkdir -p dist
echo "Compiling..."
swiftc -parse-as-library -O \
  -target arm64-apple-macos14.0 \
  $(find Sources/CCCXUsageMonitor -name '*.swift') \
  -o "$BIN"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BIN" "$APP/Contents/MacOS/CCCXUsageMonitor"
cp Support/Info.plist "$APP/Contents/"
if [ -f Support/CCCXUsageMonitor.icns ]; then
  cp Support/CCCXUsageMonitor.icns "$APP/Contents/Resources/"
fi
codesign --force --sign - "$APP"
echo "Built $APP"

# --install: copy to /Applications
if [ "${1:-}" = "--install" ]; then
  pkill -f "MacOS/UsageBar" 2>/dev/null || true
  pkill -f "MacOS/CCCXUsageMonitor" 2>/dev/null || true
  rm -rf /Applications/UsageBar.app "/Applications/Usage CCCX.app" "/Applications/CCCX Usage Monitor.app"
  cp -R "$APP" /Applications/
  echo "Installed /Applications/CCCX Usage Monitor.app"
  echo "Run: open '/Applications/CCCX Usage Monitor.app'"
else
  echo "Run: open '$APP'   (or Scripts/build-app.sh --install)"
fi
