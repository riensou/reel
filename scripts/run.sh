#!/usr/bin/env bash
# Rebuilds and relaunches reel.app.
set -euo pipefail
cd "$(dirname "$0")/.."
pkill -x reel 2>/dev/null || true
scripts/bundle.sh "${1:-debug}"
open build.noindex/reel.app
