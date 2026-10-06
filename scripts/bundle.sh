#!/usr/bin/env bash
# Builds build/reel.app (ad-hoc signed). Usage: scripts/bundle.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
config="${1:-release}"
swift build -c "$config"
bin="$(swift build -c "$config" --show-bin-path)/reel"
app=build/reel.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/reel"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - --identifier dev.reel "$app"
echo "$app"
