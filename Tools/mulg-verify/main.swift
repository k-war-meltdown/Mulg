#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import MulgContracts
import MulgLibrary

enum VerificationFailure: Error {
    case usage, appleSiliconRequired, probeFailed(String)
}

func requireAppleSilicon() throws {
    #if arch(arm64)
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else {
        throw VerificationFailure.probeFailed("macOS 27 is required")
    }
    #else
    throw VerificationFailure.appleSiliconRequired
    #endif
}

func pair(in app: URL) -> (framework: URL, bridge: URL) {
    (app.appendingPathComponent("Contents/Frameworks/MulgRuntime.framework"),
     app.appendingPathComponent("Contents/PlugIns/MulgBridge.bundle"))
}

func stamp(_ framework: URL, _ bridge: URL) throws {
    try RuntimeInstaller.validateBinary(framework.appendingPathComponent("MulgRuntime"), platform: 6)
    try RuntimeInstaller.validateBinary(bridge.appendingPathComponent("Contents/MacOS/MulgBridge"), platform: 1)
    try RuntimeManifest().write(to: RuntimeManifest.frameworkURL(framework))
    try RuntimeManifest().write(to: bridge.appendingPathComponent("Contents/Resources/" + RuntimeManifest.fileName))
}

/// Builds and bundles a real Catalyst UIKit app linked to the same runtime as installed games.
func buildProbe(host: URL, output: URL) throws {
    try requireAppleSilicon()
    let artifacts = pair(in: host)
    try RuntimeInstaller.validatePair(framework: artifacts.framework, bridge: artifacts.bridge)
    let derived = output.appendingPathComponent("DerivedData")
    try Command.run("/usr/bin/xcodebuild", ["build", "-scheme", "MulgRuntimeProbe", "-configuration", "Release",
        "-destination", "generic/platform=macOS,variant=Mac Catalyst", "-derivedDataPath", derived.path,
        "ARCHS=arm64", "CODE_SIGNING_ALLOWED=NO"],
        directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Apps/Probe"))
    let products = derived.appendingPathComponent("Build/Products/Release-maccatalyst")
    let app = output.appendingPathComponent("MulgRuntimeProbe.app")
    let files = FileManager.default
    try? files.removeItem(at: app)
    let executable = app.appendingPathComponent("Contents/MacOS/MulgRuntimeProbe")
    try files.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try files.copyItem(at: products.appendingPathComponent("MulgRuntimeProbe"), to: executable)
    try RuntimeInstaller.validateBinary(executable, platform: 6)
    // The consumer must load the bundled production runtime, never a statically linked copy.
    var binary = try Data(contentsOf: executable)
    let canonical = "@executable_path/../Frameworks/MulgRuntime.framework/MulgRuntime"
    let libraries = try MachOBinary.loadedLibraries(in: binary)
    let runtimes = libraries.filter { $0.contains("MulgRuntime.framework/") || $0.hasSuffix("libMulgRuntime.dylib") }
    guard !runtimes.isEmpty else { throw VerificationFailure.probeFailed("Probe did not link the dynamic runtime") }
    for runtime in runtimes { try MachOBinary.replaceLibrary(&binary, from: runtime, to: canonical) }
    try binary.write(to: executable, options: .atomic)
    try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let frameworks = app.appendingPathComponent("Contents/Frameworks")
    try files.createDirectory(at: frameworks, withIntermediateDirectories: true)
    let packageFrameworks = products.appendingPathComponent("PackageFrameworks")
    for framework in try files.contentsOfDirectory(at: packageFrameworks, includingPropertiesForKeys: nil)
        where framework.pathExtension == "framework" {
        try files.copyItem(at: framework, to: frameworks.appendingPathComponent(framework.lastPathComponent))
    }
    let runtime = frameworks.appendingPathComponent("MulgRuntime.framework")
    if files.fileExists(atPath: runtime.path) { try files.removeItem(at: runtime) }
    try files.copyItem(at: artifacts.framework, to: runtime)
    let bridge = app.appendingPathComponent("Contents/PlugIns/MulgBridge.bundle")
    try files.createDirectory(at: bridge.deletingLastPathComponent(), withIntermediateDirectories: true)
    try files.copyItem(at: artifacts.bridge, to: bridge)
    let info: [String: Any] = ["CFBundleIdentifier": "io.mulg.RuntimeProbe", "CFBundleExecutable": "MulgRuntimeProbe",
        "CFBundleName": "Mulg Runtime Probe", "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
        "CFBundleShortVersionString": MulgVersion.current, "LSMinimumSystemVersion": "27.0",
        "UIDeviceFamily": [2], "NSPrincipalClass": "UIApplication", "NSHighResolutionCapable": true]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
    // Frameworks first, then the app. No game entitlements or cloud credentials are used.
    for framework in try files.contentsOfDirectory(at: frameworks, includingPropertiesForKeys: nil) {
        try Command.run("/usr/bin/codesign", ["--force", "--sign", "-", framework.path])
    }
    try Command.run("/usr/bin/codesign", ["--force", "--sign", "-", bridge.path])
    try Command.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
    try Command.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    print(app.path)
}

func runProbe(app: URL, report: URL) throws {
    try requireAppleSilicon()
    let files = FileManager.default
    try files.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? files.removeItem(at: report)
    let process = Process()
    process.executableURL = app.appendingPathComponent("Contents/MacOS/MulgRuntimeProbe")
    process.arguments = [report.path]
    try process.run()
    let deadline = Date().addingTimeInterval(60)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
    if process.isRunning { process.terminate(); throw VerificationFailure.probeFailed("Probe exceeded 60 seconds") }
    let data = try Data(contentsOf: report)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          json["passed"] as? Bool == true, process.terminationStatus == 0 else {
        throw VerificationFailure.probeFailed(String(decoding: data, as: UTF8.self))
    }
    print("Catalyst runtime probe passed: \(report.path)")
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    switch args {
    case ["host"]: try requireAppleSilicon(); print("Apple Silicon / macOS 27 verified")
    case let args where args.count == 3 && args[0] == "stamp":
        try stamp(URL(fileURLWithPath: args[1]), URL(fileURLWithPath: args[2]))
    case let args where args.count == 2 && args[0] == "bundle":
        let artifacts = pair(in: URL(fileURLWithPath: args[1]))
        try RuntimeInstaller.validatePair(framework: artifacts.framework, bridge: artifacts.bridge)
        print("Runtime and bridge match this build and contain ARM64 code")
    case let args where args.count == 3 && args[0] == "probe-build":
        try buildProbe(host: URL(fileURLWithPath: args[1]), output: URL(fileURLWithPath: args[2]))
    case let args where args.count == 3 && args[0] == "probe-run":
        try runProbe(app: URL(fileURLWithPath: args[1]), report: URL(fileURLWithPath: args[2]))
    default: throw VerificationFailure.usage
    }
} catch {
    FileHandle.standardError.write(Data("mulg-verify: \(error)\nUsage: host | stamp <framework> <bridge> | bundle <Mulg.app> | probe-build <Mulg.app> <output> | probe-run <probe.app> <report.json>\n".utf8))
    exit(1)
}
#endif
