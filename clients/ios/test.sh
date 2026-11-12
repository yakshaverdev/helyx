#!/usr/bin/env bash
# Runs the unit tests of the Helyx app on the iOS Simulator: builds the app
# with build.sh, then runs `xcodebuild test` on the same destination. Prints
# `passed` or `failed` as its last line, and writes the output to test.log
# (`clients/ios/README.md`). Set HELYX_SIMULATOR to another iPhone.
set -uo pipefail
cd "$(dirname "$0")" || exit 1

simulator=${HELYX_SIMULATOR:-iPhone 17}
destination="platform=iOS Simulator,name=$simulator"
log=test.log

if ! ./build.sh; then
  echo "log: $PWD/build.log"
  echo failed
  exit 1
fi

(
  set -e
  echo "==> xcodebuild test ($destination)"
  xcodebuild test \
    -project Helyx.xcodeproj \
    -scheme Helyx \
    -configuration Debug \
    -destination "$destination" \
    -derivedDataPath build
) >"$log" 2>&1
status=$?

if [ "$status" -eq 0 ]; then
  echo passed
else
  echo "log: $PWD/$log"
  echo failed
  exit 1
fi
