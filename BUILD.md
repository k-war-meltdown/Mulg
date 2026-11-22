# Build Mulg from source

Use an **Apple silicon Mac** with **macOS 27 or later** and **Xcode 27 with Swift 6.4 and Mac Catalyst support**. Run from the root of your checkout. Adjust `DEVELOPER_DIR` if Xcode is installed elsewhere.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
FASTLANE=1 xcodebuild build \
  -project Host/Mulg.xcodeproj \
  -scheme Mulg \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath .build/Xcode \
  ARCHS=arm64 CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO
```

The build produces `.build/Xcode/Build/Products/Release/Mulg.app` with the Catalyst runtime and AppKit bridge bundled. Xcode uses a local ad hoc signature. An Apple Developer account, certificate, and notarization are unnecessary for this build. Bring your own compatible game files.

Run `swift test` to check the modules, and see the [module reference](MODULES.md) for the code layout.
