#!/usr/bin/env bash
# Builds build/reel.app. Usage: scripts/bundle.sh [debug|release]
# Signs with the "reel-dev" identity (scripts/make-dev-cert.sh) so macOS keeps
# permissions across rebuilds; falls back to ad-hoc signing without it.
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
identity="-"
if security find-identity -p codesigning | grep -q '"reel-dev"'; then
    identity="reel-dev"
else
    echo "warning: no reel-dev identity; ad-hoc signing (run scripts/make-dev-cert.sh)" >&2
fi
codesign --force --sign "$identity" --identifier dev.reel "$app"
echo "$app"
