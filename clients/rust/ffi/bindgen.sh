#!/usr/bin/env bash
# Generates the Swift bindings of this crate into generated/ (never committed):
# the library, then the generator of the crate itself, in library mode
# (docs/features/client-kit.md, "Bindings for Swift").
set -euo pipefail
cd "$(dirname "$0")"

mise exec -- cargo build --locked --features bindgen --lib
case "$(uname -s)" in
  Darwin) library=../target/debug/libhelyx_client_ffi.dylib ;;
  *) library=../target/debug/libhelyx_client_ffi.so ;;
esac

mise exec -- cargo run --locked --features bindgen --bin uniffi-bindgen -- \
  generate --library "$library" --language swift --out-dir generated
