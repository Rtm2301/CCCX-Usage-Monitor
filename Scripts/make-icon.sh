#!/bin/bash
# Usage: Scripts/make-icon.sh <path-to-1024px-png>
# Converts a 1024x1024 PNG into Support/UsageBar.icns.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:?usage: Scripts/make-icon.sh <icon.png>}"
ICONSET=$(mktemp -d)/UsageBar.iconset
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
  sips -z $size $size "$SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o Support/UsageBar.icns
echo "Created Support/UsageBar.icns — rebuild with Scripts/build-app.sh --install"
