# The iOS app

The Helyx app for the iPhone: a SwiftUI shell over the Rust client kit
(`docs/features/ios-app.md`). The app draws the snapshot of one `Connection`
and calls its methods; every rule lives in `clients/rust`.

## Build

Xcode 26 and `xcodegen` are needed. From this folder:

```sh
./build.sh     # the app for the iOS Simulator, into build/ (Git ignores it)
./build.sh device   # the library for a device, and an unsigned app
./test.sh      # the unit tests of the store, on the Simulator
```

Each script writes its full output to `build.log` or `test.log`, and prints
`passed` or `failed` as its last line. `test.sh` runs `build.sh` first. The
Rust targets are added once: `mise exec -- rustup target add
aarch64-apple-ios-sim aarch64-apple-ios`.

`test.sh` uses the iPhone 17 simulator. Set `HELYX_SIMULATOR` to another
iPhone that this Mac has.

The build runs the steps in this order: the static library of
`helyx-client-ffi` for the simulator, `ffi/bindgen.sh` for the Swift bindings,
a copy of the bindings to `Bindings/` and of the library to `Rust/`,
`xcodegen generate`, and `xcodebuild build`. The Xcode project, `Bindings/`,
`Rust/`, `build/`, and the logs are not committed: a build makes them.

## Rename

A product changes these, and nothing else, to carry its own name:

- `project.yml`: `PRODUCT_NAME` (the name, which the display name follows),
  and `PRODUCT_BUNDLE_IDENTIFIER` (the bundle identifier, which is also the
  Keychain service of the token).
- `Helyx/Assets.xcassets/AppIcon.appiconset`: the 1024 × 1024 icon.

The screens, the store, and the views are product code: change them in
`Helyx/`.
