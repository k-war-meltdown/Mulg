// swift-tools-version: 6.4
import PackageDescription

// A separate consumer package guarantees a dynamic runtime dependency. A target in the
// root package would statically fold runtime objects into the probe executable instead.
let package = Package(
    name: "MulgRuntimeProbe",
    platforms: [.macCatalyst("27.0")],
    products: [.executable(name: "MulgRuntimeProbe", targets: ["MulgRuntimeProbe"])],
    dependencies: [.package(path: "../..")],
    targets: [.executableTarget(name: "MulgRuntimeProbe",
        dependencies: [.product(name: "MulgRuntime", package: "Mulg")], path: ".", exclude: ["Package.swift"])]
)
