import Foundation
import Testing
import MulgContracts
@testable import MulgEngine

@Suite("Plugin dependency policy")
struct PluginDependencyTests {
    @Test func metadataPresenceContentsAndMinimalRecoveryAreEnforced() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let binary = folder.appendingPathComponent("A.dylib"), card = folder.appendingPathComponent("A.module.json")
        try image().write(to: binary)
        var settings = EngineSettings()
        settings.trustedPluginHashes["A.dylib"] = try #require(PluginLoader.sha256(of: binary))
        #expect(PluginLoader(folder: folder, engine: settings, safeMode: false, executable: nil).decide(for: binary) == .skipUntrusted)
        settings.trustedPluginHashes["A.module.json"] = "absent"
        #expect(PluginLoader(folder: folder, engine: settings, safeMode: false, executable: nil).preflight(for: binary) == .load)
        try JSONEncoder().encode(PluginCard(id: "A", runtimeProtocol: MulgVersion.runtimeProtocol, experimental: false)).write(to: card)
        #expect(PluginLoader(folder: folder, engine: settings, safeMode: false, executable: nil).decide(for: binary) == .skipHashMismatch)
        settings.trustedPluginHashes["A.module.json"] = try #require(PluginLoader.sha256(of: card))
        let normal = PluginLoader(folder: folder, engine: settings, safeMode: true, executable: nil)
        #expect(normal.preflight(for: binary) == .load)
        #expect(PluginLoader(folder: folder, engine: settings, safeMode: true, executable: nil, minimalRecovery: true).preflight(for: binary) == .skipSafeMode)
        try JSONEncoder().encode(PluginCard(id: "other", runtimeProtocol: MulgVersion.runtimeProtocol, experimental: false)).write(to: card)
        #expect(normal.decide(for: binary) == .skipHashMismatch)
        try FileManager.default.removeItem(at: card)
        #expect(normal.decide(for: binary) == .skipHashMismatch)
        settings.trustedPluginHashes["A.module.json"] = "absent"
        try FileManager.default.createSymbolicLink(at: card, withDestinationURL: folder.appendingPathComponent("missing.json"))
        #expect(PluginLoader(folder: folder, engine: settings, safeMode: false, executable: nil).decide(for: binary) == .skipInvalidCard)
    }

    private func image(dependencies: [(String, Bool)] = [], runpaths: [String] = []) -> Data {
        func words(_ values: [UInt32]) -> Data {
            values.reduce(into: Data()) { data, value in
                withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
            }
        }
        var commands: [Data] = []
        for (path, weak) in dependencies {
            let size = (24 + path.utf8.count + 1 + 7) / 8 * 8
            var command = words([weak ? 0x8000_0018 : 0xc, UInt32(size), 24, 0, 0, 0])
            command.append(contentsOf: path.utf8); command.append(Data(count: size - command.count))
            commands.append(command)
        }
        for path in runpaths {
            let size = (12 + path.utf8.count + 1 + 7) / 8 * 8
            var command = words([0x8000_001c, UInt32(size), 12])
            command.append(contentsOf: path.utf8); command.append(Data(count: size - command.count))
            commands.append(command)
        }
        var data = words([0xfeedfacf, 0x0100000c, 0, 6, UInt32(commands.count),
                          UInt32(commands.reduce(0) { $0 + $1.count }), 0, 0])
        commands.forEach { data.append($0) }
        return data
    }

    @Test func everyDependentPluginMustPassPolicyBeforeLoading() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mulg-plugin-policy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Frameworks/UserPlugins")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let main = root.appendingPathComponent("Game"), a = folder.appendingPathComponent("A.dylib")
        let b = folder.appendingPathComponent("B.dylib"), helper = folder.deletingLastPathComponent().appendingPathComponent("Helper.dylib")
        try image(runpaths: ["@executable_path/Frameworks"]).write(to: main)
        try image(dependencies: [("@rpath/Helper.dylib", false)]).write(to: a)
        try image(dependencies: [("@loader_path/UserPlugins/B.dylib", false)]).write(to: helper)
        try image(dependencies: [("@loader_path/A.dylib", false)]).write(to: b)
        var settings = EngineSettings()
        settings.trustedPluginHashes = ["A.dylib": try #require(PluginLoader.sha256(of: a)),
                                       "B.dylib": try #require(PluginLoader.sha256(of: b)), "A.module.json": "absent"]
        func card(_ experimental: Bool = false, protocol version: Int = MulgVersion.runtimeProtocol) throws {
            try JSONEncoder().encode(PluginCard(id: "B", runtimeProtocol: version, experimental: experimental))
                .write(to: b.deletingPathExtension().appendingPathExtension("module.json"))
            settings.trustedPluginHashes["B.module.json"] = try #require(PluginLoader.sha256(of: b.deletingPathExtension().appendingPathExtension("module.json")))
        }
        try card()
        #expect(PluginLoader(folder: folder, engine: settings, safeMode: false, executable: main).preflight(for: a) == .load)
        settings.disabledModules = ["B"]
        let disabled = PluginLoader(folder: folder, engine: settings, safeMode: false, executable: main)
        #expect(disabled.preflight(for: a) == .skipDependency(b.path))
        #expect(disabled.loadAll().first?.decision == .skipDependency(b.path))
        #expect(disabled.loadAll().first?.loadError == nil, "No dlopen attempt for a rejected closure")
        settings.disabledModules = []
        try card(true)
        try JSONEncoder().encode(PluginCard(id: "A", runtimeProtocol: MulgVersion.runtimeProtocol, experimental: false))
            .write(to: a.deletingPathExtension().appendingPathExtension("module.json"))
        settings.trustedPluginHashes["A.module.json"] = try #require(PluginLoader.sha256(of: a.deletingPathExtension().appendingPathExtension("module.json")))
        #expect(PluginLoader(folder: folder, engine: settings, safeMode: true, executable: main).preflight(for: a) == .skipDependency(b.path))
        try card(protocol: MulgVersion.runtimeProtocol + 1)
        #expect(PluginLoader(folder: folder, engine: settings, safeMode: false, executable: main).preflight(for: a) == .skipDependency(b.path))
        try card()
        settings.trustedPluginHashes["B.dylib"] = String(repeating: "0", count: 64)
        #expect(PluginLoader(folder: folder, engine: settings, safeMode: false, executable: main).preflight(for: a) == .skipDependency(b.path))
        settings.trustedPluginHashes["B.dylib"] = nil
        #expect(PluginLoader(folder: folder, engine: settings, safeMode: false, executable: main).preflight(for: a) == .skipDependency(b.path))
    }

    @Test func missingWeakDependenciesAreAllowedButRequiredOnesAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mulg-plugin-weak-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("A.dylib")
        var settings = EngineSettings(); settings.allowUnverifiedPlugins = true
        let loader = PluginLoader(folder: root, engine: settings, safeMode: false, executable: nil)
        try image(dependencies: [("@loader_path/Missing.dylib", true)]).write(to: file)
        #expect(loader.preflight(for: file) == .load)
        try image(dependencies: [("@loader_path/Missing.dylib", false)]).write(to: file)
        #expect(loader.preflight(for: file) == .skipDependency("@loader_path/Missing.dylib"))
    }
}
