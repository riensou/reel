#!/usr/bin/env bash
# Builds a release reel.app and zips it for a GitHub release:
#   scripts/release.sh 0.2.0   →   dist/reel-0.2.0.zip
# Note: without a Developer ID signature + notarization, downloaders must
# right-click → Open the first time (Gatekeeper).
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?usage: scripts/release.sh <version>}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" Resources/Info.plist
scripts/bundle.sh release
mkdir -p dist
ditto -c -k --keepParent build.noindex/reel.app "dist/reel-$version.zip"
echo "dist/reel-$version.zip"
