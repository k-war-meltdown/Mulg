// swift-tools-version: 5.9
//
// Local wrapper around the vendored Sparkle 2.10.0 release
// (Sparkle-for-Swift-Package-Manager.zip, SHA-256
// 17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959).
// Replaces the upstream package's remote binary target so builds need no download.

import PackageDescription

let package = Package(
    name: "Sparkle",
    platforms: [.macOS(.v10_13)],
    products: [
        .library(name: "Sparkle", targets: ["Sparkle"])
    ],
    targets: [
        .binaryTarget(name: "Sparkle", path: "Sparkle.xcframework")
    ]
)
