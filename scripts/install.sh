#!/usr/bin/env bash
# Builds a release reel.app and installs it to /Applications, replacing any
# running copy. Signed with the same reel-dev identity, so macOS permissions
# carry over.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/bundle.sh release
osascript -e 'quit app "reel"' 2>/dev/null || true
pkill -x reel 2>/dev/null || true
sleep 0.5
rm -rf /Applications/reel.app
cp -R build.noindex/reel.app /Applications/reel.app
open /Applications/reel.app
echo "installed /Applications/reel.app"
