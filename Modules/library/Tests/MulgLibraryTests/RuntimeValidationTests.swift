#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import MulgContracts
import Testing
@testable import MulgLibrary

@Suite("Runtime artifact validation")
struct RuntimeValidationTests {
    @Test(arguments: [false, true]) func checksMetadataPlatformAndInstalledFingerprint(versioned: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let framework = root.appendingPathComponent("MulgRuntime.framework")
        let bridge = root.appendingPathComponent("MulgBridge.bundle")
        let runtimeBinary = framework.appendingPathComponent("MulgRuntime")
        let bridgeBinary = bridge.appendingPathComponent("Contents/MacOS/MulgBridge")
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        if versioned {
            try FileManager.default.createDirectory(at: framework.appendingPathComponent("Versions/A/Resources"),
                                                    withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Resources").path,
                                                       withDestinationPath: "Versions/A/Resources")
        }
        try FileManager.default.createDirectory(at: bridgeBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeBinary(platform: 6).write(to: runtimeBinary)
        try makeBinary(platform: 1).write(to: bridgeBinary)
        try RuntimeManifest().write(to: RuntimeManifest.frameworkURL(framework))
        let bridgeManifest = bridge.appendingPathComponent("Contents/Resources/" + RuntimeManifest.fileName)
        try RuntimeManifest().write(to: bridgeManifest)
        try RuntimeInstaller.validatePair(framework: framework, bridge: bridge)
        let installed = root.appendingPathComponent("installed.framework")
        try RuntimeInstaller.replace(installed, with: framework) {
            try RuntimeInstaller.validatePair(framework: $0, bridge: bridge)
        }
        try RuntimeInstaller.validateInstalled(installed, bundled: framework, bridge: bridge)
        var changed = try Data(contentsOf: installed.appendingPathComponent("MulgRuntime"))
        changed[changed.count - 1] ^= 1
        try changed.write(to: installed.appendingPathComponent("MulgRuntime"))
        #expect(throws: RuntimeInstaller.ValidationFailure.self) {
            try RuntimeInstaller.validateInstalled(installed, bundled: framework, bridge: bridge)
        }
        try RuntimeManifest(runtimeProtocol: MulgVersion.runtimeProtocol + 1).write(to: bridgeManifest)
        #expect(throws: RuntimeInstaller.ValidationFailure.self) {
            try RuntimeInstaller.validatePair(framework: framework, bridge: bridge)
        }
        try RuntimeManifest().write(to: bridgeManifest)
        try makeBinary(platform: 2).write(to: runtimeBinary)
        #expect(throws: RuntimeInstaller.ValidationFailure.self) {
            try RuntimeInstaller.validatePair(framework: framework, bridge: bridge)
        }
    }
    @Test func failedStagingValidationKeepsWorkingRuntime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("installed")
        let candidate = root.appendingPathComponent("candidate")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("working".utf8).write(to: target)
        try Data("broken".utf8).write(to: candidate)
        #expect(throws: RuntimeInstaller.ValidationFailure.self) {
            try RuntimeInstaller.replace(target, with: candidate) { _ in
                throw RuntimeInstaller.ValidationFailure.installedCopyDiffers
            }
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "working")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["candidate", "installed"])
    }
}
#endif
