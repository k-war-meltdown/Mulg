<p align="center">
  <img src="Modules/gui/Design/icon-dark.png" alt="Mulg app logo" width="116">
</p>

<h1 align="center">Mulg</h1>

<p align="center">Play compatible iPhone and iPad games on Apple silicon Macs.</p>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#tested-games">Tested games</a> ·
  <a href="#build-from-source">Build from source</a> ·
  <a href="https://github.com/k-war-meltdown/Mulg/issues/new?template=bug-report.yml">Report a bug</a>
</p>

Mulg is a macOS game launcher and runtime with a game library, desktop input mapping, and per-game display and performance profiles. Import a compatible IPA you have permission to use, choose your settings, and launch it from the library.

## Features

| Area | What's included |
| --- | --- |
| **True 4K rendering** | Choose the fixed **4K** preset (3840 × 2160) with Retina enabled, then use **Force selected resolution** for compatible games that render below the selected size. Native 4K and MetalFX upscaling are separate options. |
| **Display** | Native macOS windows and full screen, external displays, 4K and 5K presets, and HDR where supported. |
| **Performance** | Per-game FPS targets up to 120 FPS where supported, frame pacing, shader caching and parallel shader compilation, scene scaling, optional MetalFX upscaling, and balanced and battery-saver profiles. Native 4K prioritizes detail. Lower render scales and MetalFX can help when the GPU limits performance. |
| **Controls** | Map keyboard, mouse, and controller input to touch controls with the in-game editor. Save per-game layouts and use bundled profiles for selected titles. |
| **Game library** | Import and manage local IPAs, choose install and data locations, and store games on external drives. Settings are saved per game. A menu-bar mode and command-line tools provide additional launch and management options. |
| **Compatibility and diagnostics** | Per-game device and launch settings, audio output controls, recovery mode, crash and hang reports, and performance snapshots. Selected games also have camera reach controls. |
| **Integrations** | Optional Discord activity, local sign-in storage, and MulgVault access protection. |

Frame rate, render resolution, and feature support vary with the game build, Mac, display, and settings. Check the render resolution in diagnostics when comparing 4K output, and record the same scene and graphics profile when comparing FPS.

## Tested games

- **Genshin Impact**
- **Honkai: Star Rail**
- **BLEACH: Soul Resonance**

These titles were tested during development. Game updates can change compatibility, and each title may support a different set of options.

## Build from source

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

## Report a bug

[Open a bug report](https://github.com/k-war-meltdown/Mulg/issues/new?template=bug-report.yml) for crashes, launch failures, control problems, or performance regressions. Include the Mulg commit or build, game version, Mac model, macOS version, and steps to reproduce. For performance reports, include render and output resolution, FPS target, MetalFX settings, and measured FPS or frame times if available.

## License and credits

The PlayCover-derived host uses [GPL-3.0](Host/LICENSE). The modules derived from PlayTools use [AGPL-3.0](Runtime/LICENSE). Dependencies under `Vendor/` carry their own notices. See [credits](CREDITS.md) for upstream projects.
