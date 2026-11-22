// swift-tools-version: 6.4
//
// Mulg's modules, built module by module (PLAN.md §1). Every module lives in Modules/<id>/
// next to its card; products that assemble modules live in Apps/; third-party code lives in
// Vendor/. The Mac app (Host/) is an Xcode project in the same folder; Runtime/
// keeps only the retired MulgKit's licence. No target here compiles their files, and nothing is fetched from other repositories.
//
// Swift Package Manager cannot mix Swift and Objective-C in one target, so a module with
// hooks has two targets: `Mulg<Module>` (Swift) and `Mulg<Module>Hooks` (Objective-C).

import PackageDescription

let package = Package(
    name: "Mulg",
    defaultLocalization: "en",
    platforms: [
        .macOS("27.0"),
        .iOS("27.0"),
        // MulgRuntime is built for Mac Catalyst, like the games it is injected into.
        .macCatalyst("27.0")
    ],
    products: [
        // Injected into every game.
        .library(name: "MulgRuntime", type: .dynamic, targets: ["MulgRuntime"]),
        // Loaded into every game as a macOS bundle (the AppKit side of the bridge).
        .library(name: "MulgBridgeAppKit", type: .dynamic, targets: ["MulgBridgeAppKit"]),
        // Shared with the Mulg app.
        .library(name: "MulgContracts", targets: ["MulgContracts"]),
        .library(name: "MulgKeymaps", targets: ["MulgKeymaps"]),
        .library(name: "MulgControlLayout", targets: ["MulgControlLayout"]),
        // Used by the Mulg app: install pipeline and the new settings pages.
        .library(name: "MulgLibrary", targets: ["MulgLibrary"]),
        .library(name: "MulgVault", targets: ["MulgVault"]),
        .library(name: "MulgGUI", targets: ["MulgGUI"]),
        .library(name: "MulgStore", targets: ["MulgStore"]),
        .executable(name: "mulg", targets: ["mulg"]),
        .executable(name: "mulg-modules", targets: ["mulg-modules"]),
        .executable(name: "mulg-verify", targets: ["mulg-verify"])
    ],
    dependencies: [
        .package(path: "Vendor/Yams")
    ],
    targets: [
        // MARK: keymaps (pure format/layout module, both processes)
        .target(name: "MulgKeymaps", path: "Modules/keymaps/Sources/MulgKeymaps"),
        // Pure HUD constraints/observations. Shares the existing map format in both processes.
        .target(name: "MulgControlLayout", dependencies: ["MulgKeymaps"],
                path: "Modules/control-layout/Sources/MulgControlLayout"),

        // MARK: contracts (both processes)
        .target(
            name: "MulgContracts",
            dependencies: ["MulgKeymaps", "MulgControlLayout"],
            path: "Modules/contracts/Sources/MulgContracts"
        ),
        .testTarget(
            name: "MulgContractsTests",
            dependencies: ["MulgContracts", "MulgKeymaps"],
            path: "Modules/contracts/Tests/MulgContractsTests"
        ),

        // MARK: bridge (game process → macOS)
        .target(
            name: "MulgBridge",
            path: "Modules/bridge/Sources/MulgBridge"
        ),
        .target(
            name: "MulgBridgeAppKit",
            dependencies: ["MulgBridge"],
            path: "Modules/bridge/Sources/MulgBridgeAppKit",
            linkerSettings: [.linkedFramework("ScreenCaptureKit", .when(platforms: [.macOS]))]
        ),
        .testTarget(
            name: "MulgBridgeAppKitTests",
            // The runtime supplies the swizzle registry the bridge resolves at run time; the tests link it.
            dependencies: ["MulgBridgeAppKit", "MulgEngineHooks"],
            path: "Modules/bridge/Tests/MulgBridgeAppKitTests"
        ),

        // MARK: engine
        .target(
            name: "MulgEngineHooks",
            path: "Modules/engine/Sources/MulgEngineHooks"
        ),
        .target(
            name: "MulgEngine",
            dependencies: ["MulgContracts", "MulgBridge", "MulgEngineHooks"],
            path: "Modules/engine/Sources/MulgEngine"
        ),
        .testTarget(
            name: "MulgEngineTests",
            dependencies: ["MulgEngine", "MulgEngineHooks", "MulgContracts"],
            path: "Modules/engine/Tests/MulgEngineTests"
        ),

        // MARK: identity
        .target(
            name: "MulgIdentityHooks",
            dependencies: ["MulgEngineHooks"],
            path: "Modules/identity/Sources/MulgIdentityHooks",
            // MGCopyAnswer; the SDK stub covers macOS, Mac Catalyst and iOS.
            // IOKit for the platform-expert answers, where it exists.
            linkerSettings: [.linkedLibrary("MobileGestalt"),
                             .linkedFramework("IOKit", .when(platforms: [.macOS, .macCatalyst]))]
        ),
        .target(
            name: "MulgIdentity",
            dependencies: ["MulgContracts", "MulgEngine", "MulgIdentityHooks"],
            path: "Modules/identity/Sources/MulgIdentity"
        ),
        .testTarget(
            name: "MulgIdentityTests",
            dependencies: ["MulgIdentity", "MulgIdentityHooks", "MulgContracts"],
            path: "Modules/identity/Tests/MulgIdentityTests"
        ),

        // MARK: display
        .target(
            name: "MulgDisplayHooks",
            dependencies: ["MulgEngineHooks"],
            path: "Modules/display/Sources/MulgDisplayHooks"
        ),
        .target(
            name: "MulgDisplay",
            dependencies: ["MulgContracts", "MulgEngine", "MulgDisplayHooks"],
            path: "Modules/display/Sources/MulgDisplay"
        ),
        .testTarget(
            name: "MulgDisplayTests",
            dependencies: ["MulgDisplay", "MulgDisplayHooks", "MulgContracts", "MulgBridgeAppKit"],
            path: "Modules/display/Tests/MulgDisplayTests"
        ),

        // MARK: graphics
        .target(
            name: "MulgGraphicsHooks",
            dependencies: ["MulgEngineHooks"],
            path: "Modules/graphics/Sources/MulgGraphicsHooks"
        ),
        .target(
            name: "MulgGraphics",
            dependencies: ["MulgContracts", "MulgEngine", "MulgGraphicsHooks"],
            path: "Modules/graphics/Sources/MulgGraphics"
        ),
        .testTarget(
            name: "MulgGraphicsTests",
            dependencies: ["MulgGraphics", "MulgGraphicsHooks", "MulgContracts", "MulgBridgeAppKit"],
            path: "Modules/graphics/Tests/MulgGraphicsTests"
        ),

        // MARK: controls
        .target(
            name: "MulgControlsHooks",
            dependencies: ["MulgEngineHooks"],
            path: "Modules/controls/Sources/MulgControlsHooks",
            linkerSettings: [.linkedFramework("IOKit", .when(platforms: [.macCatalyst]))]
        ),
        .target(
            name: "MulgControls",
            dependencies: ["MulgContracts", "MulgControlLayout", "MulgEngine", "MulgEngineHooks", "MulgBridge", "MulgControlsHooks"],
            path: "Modules/controls/Sources/MulgControls"
        ),
        .testTarget(
            name: "MulgControlsTests",
            dependencies: ["MulgControls", "MulgControlsHooks", "MulgContracts", "MulgEngine"],
            path: "Modules/controls/Tests/MulgControlsTests"
        ),

        // MARK: mapper
        .target(
            name: "MulgMapper",
            dependencies: ["MulgContracts", "MulgKeymaps", "MulgEngine"],
            path: "Modules/mapper/Sources/MulgMapper"
        ),
        .testTarget(
            name: "MulgMapperTests",
            dependencies: ["MulgMapper", "MulgContracts", "MulgKeymaps", "MulgEngine"],
            path: "Modules/mapper/Tests/MulgMapperTests"
        ),

        // MARK: camera (Camera reach: finds and raises the game's zoom limit by value)
        .target(
            name: "MulgCameraHooks",
            path: "Modules/camera/Sources/MulgCameraHooks"
        ),
        .target(
            name: "MulgCamera",
            dependencies: ["MulgContracts", "MulgEngine", "MulgCameraHooks"],
            path: "Modules/camera/Sources/MulgCamera"
        ),
        .testTarget(
            name: "MulgCameraTests",
            dependencies: ["MulgCamera", "MulgCameraHooks", "MulgContracts"],
            path: "Modules/camera/Tests/MulgCameraTests"
        ),

        // MARK: diagnostics
        .target(
            name: "MulgDiagnosticsHooks",
            path: "Modules/diagnostics/Sources/MulgDiagnosticsHooks"
        ),
        .target(
            name: "MulgDiagnostics",
            dependencies: ["MulgContracts", "MulgEngine", "MulgDiagnosticsHooks"],
            path: "Modules/diagnostics/Sources/MulgDiagnostics"
        ),
        .testTarget(
            name: "MulgDiagnosticsTests",
            dependencies: ["MulgDiagnostics", "MulgContracts"],
            path: "Modules/diagnostics/Tests/MulgDiagnosticsTests"
        ),

        // MARK: integrations (native vault and game-side MulgChain)
        .target(
            name: "MulgVault",
            dependencies: ["MulgContracts", "MulgLibrary"],
            path: "Modules/integrations/Sources/MulgVault"
        ),
        .target(
            name: "MulgIntegrationsHooks",
            dependencies: ["MulgEngineHooks"],
            path: "Modules/integrations/Sources/MulgIntegrationsHooks",
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("AuthenticationServices")]
        ),
        .target(
            name: "MulgIntegrations",
            dependencies: ["MulgContracts", "MulgEngine", "MulgIntegrationsHooks"],
            path: "Modules/integrations/Sources/MulgIntegrations",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "MulgIntegrationsTests",
            dependencies: ["MulgIntegrations", "MulgContracts", "MulgVault"],
            path: "Modules/integrations/Tests/MulgIntegrationsTests"
        ),

        // MARK: library (Mulg app: install pipeline)
        .target(
            name: "MulgLibrary",
            dependencies: ["MulgContracts"],
            path: "Modules/library/Sources/MulgLibrary"
        ),
        .testTarget(
            name: "MulgLibraryTests",
            dependencies: ["MulgLibrary", "MulgContracts"],
            path: "Modules/library/Tests/MulgLibraryTests"
        ),

        // MARK: store (Mulg app: shared game profiles, compatibility badges, sharing)
        .target(
            name: "MulgStore",
            dependencies: ["MulgContracts", "MulgLibrary"],
            path: "Modules/store/Sources/MulgStore"
        ),
        .testTarget(
            name: "MulgStoreTests",
            dependencies: ["MulgStore", "MulgContracts", "MulgLibrary"],
            path: "Modules/store/Tests/MulgStoreTests"
        ),

        // MARK: gui (Mulg app: Performance tab, readiness check, Modules page, services, Shortcuts)
        .target(
            name: "MulgGUI",
            dependencies: ["MulgContracts", "MulgLibrary", "MulgStore"],
            path: "Modules/gui/Sources/MulgGUI",
            resources: [.process("Localizable.xcstrings"), .process("Assets.xcassets"), .copy("Keymaps")]
        ),
        .testTarget(
            name: "MulgGUITests",
            dependencies: ["MulgGUI", "MulgContracts"],
            path: "Modules/gui/Tests/MulgGUITests"
        ),

        // MARK: runtime (assembles the game-side modules)
        .target(
            name: "MulgRuntimeBoot",
            path: "Apps/Runtime/Sources/MulgRuntimeBoot"
        ),
        .target(
            name: "MulgRuntime",
            dependencies: [
                "MulgRuntimeBoot", "MulgContracts", "MulgBridge", "MulgEngine", "MulgIdentity",
                "MulgDisplay", "MulgGraphics", "MulgControls", "MulgMapper", "MulgCamera", "MulgDiagnostics", "MulgIntegrations"
            ],
            path: "Apps/Runtime/Sources/MulgRuntime"
        ),

        // MARK: tools
        .executableTarget(
            name: "mulg-verify",
            dependencies: ["MulgLibrary", "MulgContracts"],
            path: "Tools/mulg-verify"
        ),
        .executableTarget(
            name: "mulg-modules",
            dependencies: [.product(name: "Yams", package: "Yams")],
            path: "Tools/mulg-modules"
        ),
        .executableTarget(
            name: "mulg",
            dependencies: ["MulgContracts", "MulgGUI"],
            path: "Tools/mulg"
        )
    ]
)
