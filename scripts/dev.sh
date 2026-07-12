#!/bin/bash
# Watch Sources/ and rebuild-and-relaunch LoopTuneApp on every save.
#
# This is a coarse "reload on save": the app restarts, but LoopTune restores
# its state on launch (connection settings, run history, last selection), so
# a relaunch costs almost nothing. For true in-place hot reloading, run
# InjectionIII alongside this script (see README).
#
# Usage: scripts/dev.sh [debug|release]
set -uo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP_PID=""

fingerprint() {
  find Sources -name '*.swift' -exec stat -f '%m %N' {} + 2>/dev/null | md5 -q
}

build_and_relaunch() {
  echo "── building ($CONFIG)…"
  if ! swift build --product LoopTuneApp -c "$CONFIG"; then
    echo "── build failed; still watching (fix and save again)"
    return
  fi
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null
    wait "$APP_PID" 2>/dev/null
  fi
  "./.build/$CONFIG/LoopTuneApp" &
  APP_PID=$!
  echo "── relaunched (pid $APP_PID)"
}

cleanup() {
  [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null
  exit 0
}
trap cleanup INT TERM

build_and_relaunch
echo "── watching Sources/ — save a Swift file to rebuild & relaunch (^C to stop)"

LAST="$(fingerprint)"
while true; do
  sleep 1
  CURRENT="$(fingerprint)"
  if [ "$CURRENT" != "$LAST" ]; then
    LAST="$CURRENT"
    build_and_relaunch
  fi
done
