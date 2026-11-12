#!/usr/bin/env bash
# Builds the Helyx app for the iOS Simulator: the static library of the
# bindings, the Swift bindings, the Xcode project, and the app. The argument
# `device` builds the library for a device instead. Prints `passed` or
# `failed` as its last line, and writes the output to build.log
# (`clients/ios/README.md`). Set HELYX_SIMULATOR to another iPhone.
set -uo pipefail
cd "$(dirname "$0")" || exit 1

arch=aarch64-apple-ios-sim
destination="platform=iOS Simulator,name=${HELYX_SIMULATOR:-iPhone 17}"
# The Simulator build is signed to run locally, which needs no team: an app
# with no signature has no Keychain. The device build here is a compile check
# only, so it is not signed.
signing=()
if [ "${1:-}" = device ]; then
  arch=aarch64-apple-ios
  destination="generic/platform=iOS"
  signing=(CODE_SIGNING_ALLOWED=NO)
fi
log=build.log

(
  set -e
  echo "==> cargo $arch"
  (cd ../rust && mise exec -- cargo build --locked --release -p helyx-client-ffi --target "$arch")
  echo "==> bindgen"
  (cd ../rust/ffi && ./bindgen.sh)
  echo "==> copy"
  mkdir -p Bindings Rust
  cp ../rust/ffi/generated/helyx_client_ffi.swift \
     ../rust/ffi/generated/helyx_client_ffiFFI.h \
     Bindings/
  # The Clang importer finds a module map named module.modulemap in an
  # include path, not one that carries the module's name.
  cp ../rust/ffi/generated/helyx_client_ffiFFI.modulemap Bindings/module.modulemap
  cp "../rust/target/$arch/release/libhelyx_client_ffi.a" Rust/
  echo "==> xcodegen"
  xcodegen generate
  echo "==> xcodebuild build ($destination)"
  xcodebuild build \
    -project Helyx.xcodeproj \
    -scheme Helyx \
    -configuration Debug \
    -destination "$destination" \
    -derivedDataPath build \
    "${signing[@]+"${signing[@]}"}"
) >"$log" 2>&1
status=$?

if [ "$status" -eq 0 ]; then
  echo passed
else
  echo "log: $PWD/$log"
  echo failed
  exit 1
fi
