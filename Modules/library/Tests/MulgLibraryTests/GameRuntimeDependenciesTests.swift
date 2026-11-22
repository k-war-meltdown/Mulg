#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import MachO
import MulgContracts
import Testing
@testable import MulgLibrary

@Suite("Game SDK runtime constructor dependencies")
struct GameRuntimeDependenciesTests {
    private let runtime = "/tmp/current/MulgRuntime.framework/MulgRuntime"

    private func write(_ binary: Data, _ path: String, in app: URL) throws -> URL {
        let file = app.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try binary.write(to: file)
        return file
    }

    private func dylib(platform: UInt32 = UInt32(PLATFORM_MACCATALYST)) -> Data {
        var binary = makeBinary(platform: platform)
        binary.setUInt32(UInt32(MH_DYLIB), at: 12)
        return binary
    }

    @Test func ordersBundledSDKsWithoutChangingCodeOrExistingDependencyPositions() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        defer { try? FileManager.default.removeItem(at: app) }
        let main = try write(makeBinary(platform: 6), "Game", in: app)
        let original = dylib()
        let sdk = try write(original, "Frameworks/SDK.framework/SDK", in: app)
        let rootSDK = try write(original, "AlternateSDK.dylib", in: app)
        try FileManager.default.setAttributes([.posixPermissions: 0o751], ofItemAtPath: sdk.path)
        #expect(try !GameRuntimeDependencies.isCurrent(in: app, mainExecutable: main, runtimePath: runtime))
        let modified = try GameRuntimeDependencies.synchronize(in: app, mainExecutable: main, runtimePath: runtime)
        #expect(Set(modified.map { $0.resolvingSymlinksInPath() })
            == Set([main, sdk, rootSDK].map { $0.resolvingSymlinksInPath() }))
        let updated = try Data(contentsOf: sdk)
        let dependencies = try MachOBinary.loadedLibraries(in: updated)
        #expect(dependencies == (try MachOBinary.loadedLibraries(in: original)) + [runtime])
        #expect(try MachOBinary.loadedLibraries(in: Data(contentsOf: rootSDK)).last == runtime)
        #expect(updated[0x400...] == original[0x400...])
        #expect((try FileManager.default.attributesOfItem(atPath: sdk.path)[.posixPermissions] as? NSNumber)?.intValue == 0o751)
        #expect(try GameRuntimeDependencies.isCurrent(in: app, mainExecutable: main, runtimePath: runtime))
        #expect(try GameRuntimeDependencies.synchronize(in: app, mainExecutable: main, runtimePath: runtime).isEmpty)
        #expect(try Data(contentsOf: sdk) == updated)
    }

    @Test func skipsNativeLibrariesRuntimeItselfUserPluginsAndSeparateProcesses() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        defer { try? FileManager.default.removeItem(at: app) }
        let main = try write(makeBinary(platform: 6), "Game", in: app)
        let exclusions = [
            ("Frameworks/Native.dylib", dylib(platform: 1)),
            ("Frameworks/MulgRuntime.framework/MulgRuntime", dylib()),
            ("Frameworks/GameRuntime.framework/MulgKit", dylib()),
            ("Frameworks/UserPlugins/Custom.dylib", dylib()),
            ("Frameworks/Helper.app/Frameworks/SDK.dylib", dylib()),
            ("Frameworks/Helper.xpc/Frameworks/SDK.dylib", dylib()),
            ("PlugIns/Widget.appex/Frameworks/SDK.dylib", dylib()),
            ("Frameworks/Helper", makeBinary(platform: 6))
        ]
        for (path, data) in exclusions { _ = try write(data, path, in: app) }
        try GameRuntimeDependencies.synchronize(in: app, mainExecutable: main, runtimePath: runtime)
        for (path, data) in exclusions { #expect(try Data(contentsOf: app.appendingPathComponent(path)) == data) }
    }

    @Test func migratesEverySDKAndRemovesDependenciesOnUninstall() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        defer { try? FileManager.default.removeItem(at: app) }
        let main = try write(makeBinary(platform: 6), "Game", in: app)
        let sdk = try write(dylib(), "Frameworks/SDK.dylib", in: app)
        let old = "/tmp/previous/MulgRuntime.framework/MulgRuntime"
        try GameRuntimeDependencies.synchronize(in: app, mainExecutable: main, runtimePath: old)
        // A main-only upgrade must not make the host skip the SDK migration.
        try MachOBinary.editLibraries(at: main, replacing: [old: runtime])
        #expect(try !GameRuntimeDependencies.isCurrent(in: app, mainExecutable: main, runtimePath: runtime))
        try GameRuntimeDependencies.synchronize(in: app, mainExecutable: main, runtimePath: runtime)
        #expect(try MachOBinary.loadedLibraries(in: Data(contentsOf: sdk)).last == runtime)
        #expect(try !MachOBinary.loadedLibraries(in: Data(contentsOf: sdk)).contains(old))
        try GameRuntimeDependencies.synchronize(in: app, mainExecutable: main, runtimePath: nil)
        #expect(try MachOBinary.loadedLibraries(in: Data(contentsOf: sdk)) == MachOBinary.loadedLibraries(in: dylib()))
        #expect(try MachOBinary.loadedLibraries(in: Data(contentsOf: main)) == MachOBinary.loadedLibraries(in: makeBinary(platform: 6)))
    }

    /// A dylib whose symbol table imports the given undefined symbols.
    private func dylib(importing names: [String]) -> Data {
        var binary = dylib()
        let commandAt = 32 + Int(binary.uint32(at: 20))
        let table = binary.count
        var strings = Data([0])
        for name in names {
            binary.appendUInt32(UInt32(strings.count))
            binary.append(contentsOf: [UInt8(N_EXT | N_UNDF), 0, 0, 1])
            binary.append(Data(count: 8))
            strings.append(contentsOf: name.utf8); strings.append(0)
        }
        let stringsAt = binary.count
        binary.append(strings)
        for (index, word) in [UInt32(LC_SYMTAB), 24, UInt32(table), UInt32(names.count),
                              UInt32(stringsAt), UInt32(strings.count)].enumerated() {
            binary.setUInt32(word, at: commandAt + index * 4)
        }
        var linkedit = Data(count: 72)
        linkedit.setUInt32(UInt32(LC_SEGMENT_64), at: 0); linkedit.setUInt32(72, at: 4)
        linkedit.replaceSubrange(8..<18, with: Data("__LINKEDIT".utf8))
        for (offset, value) in [(24, UInt64(0x100000)), (32, 0x4000), (40, UInt64(table)), (48, UInt64(binary.count - table))] {
            Swift.withUnsafeBytes(of: value.littleEndian) { linkedit.replaceSubrange(offset..<(offset + 8), with: $0) }
        }
        binary.replaceSubrange((commandAt + 24)..<(commandAt + 96), with: linkedit)
        binary.setUInt32(binary.uint32(at: 16) + 2, at: 16)
        binary.setUInt32(binary.uint32(at: 20) + 96, at: 20)
        return binary
    }

    @Test func leavesSDKsThatInspectLoadedImagesAsShipped() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        defer { try? FileManager.default.removeItem(at: app) }
        let main = try write(makeBinary(platform: 6), "Game", in: app)
        let inspecting = dylib(importing: ["_open", "__dyld_image_count", "__dyld_get_image_name"])
        let guarded = try write(inspecting, "Frameworks/Guard.framework/Guard", in: app)
        let ordinary = try write(dylib(importing: ["_open", "__dyld_image_count"]), "Frameworks/SDK.dylib", in: app)
        #expect(try MachOBinary.inspectsLoadedImages(inspecting))
        #expect(try !MachOBinary.inspectsLoadedImages(Data(contentsOf: ordinary)))
        try GameRuntimeDependencies.synchronize(in: app, mainExecutable: main, runtimePath: runtime)
        #expect(try Data(contentsOf: guarded) == inspecting)
        #expect(try MachOBinary.loadedLibraries(in: Data(contentsOf: ordinary)).last == runtime)
        #expect(try MachOBinary.loadedLibraries(in: Data(contentsOf: main)).last == runtime)
        #expect(try GameRuntimeDependencies.isCurrent(in: app, mainExecutable: main, runtimePath: runtime))

        // Games converted by older builds lose the runtime dependency on refresh.
        try MachOBinary.editLibraries(at: guarded, adding: [runtime])
        #expect(try !GameRuntimeDependencies.isCurrent(in: app, mainExecutable: main, runtimePath: runtime))
        try GameRuntimeDependencies.synchronize(in: app, mainExecutable: main, runtimePath: runtime)
        #expect(try MachOBinary.loadedLibraries(in: Data(contentsOf: guarded)) == MachOBinary.loadedLibraries(in: inspecting))
        #expect(try GameRuntimeDependencies.isCurrent(in: app, mainExecutable: main, runtimePath: runtime))
    }

    @Test func refusesOccupiedHeaderPaddingWithoutChangingSDKBytes() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        defer { try? FileManager.default.removeItem(at: app) }
        let main = try write(makeBinary(platform: 6), "Game", in: app)
        var occupied = dylib()
        occupied[32 + Int(occupied.uint32(at: 20))] = 0xff
        let sdk = try write(occupied, "Frameworks/SDK.dylib", in: app)
        #expect(throws: MachOBinary.Failure.noRoomForLoadCommands) {
            try GameRuntimeDependencies.synchronize(in: app, mainExecutable: main, runtimePath: runtime)
        }
        #expect(try Data(contentsOf: sdk) == occupied)
    }

    @Test func installerAddsSDKDependencyBeforePreparingAndSigning() async throws {
        let app = try InstallerTests().makeApp()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let sdk = try write(dylib(platform: UInt32(PLATFORM_IOS)), "Frameworks/SDK.dylib", in: app)
        let main = app.appendingPathComponent("Game")
        let wanted = runtime
        var settings = GameSettings(bundleIdentifier: "com.example.game")
        try await GameInstaller.install(app: app,
            options: .init(runtimePath: wanted, entitlements: URL(fileURLWithPath: "/unused.plist")),
            settings: &settings, prepare: { working in
                #expect((try? GameRuntimeDependencies.isCurrent(in: working, mainExecutable: main, runtimePath: wanted)) == true)
            }, preflight: { _, _ in }, sign: { _ in
                #expect((try? MachOBinary.loadedLibraries(in: Data(contentsOf: sdk)))?.last == wanted)
            })
    }

    @Test func excludesSDKsSharedWithHelpersAndTheirTransitiveDependencies() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        defer { try? FileManager.default.removeItem(at: app) }
        let main = try write(makeBinary(platform: 6), "Game", in: app)
        let sharedData = dylib()
        let shared = try write(sharedData, "Frameworks/Shared.dylib", in: app)
        let transitive = try write(dylib(), "Frameworks/Support.dylib", in: app)
        try MachOBinary.editLibraries(at: shared, adding: ["@loader_path/Support.dylib"])
        let sharedBefore = try Data(contentsOf: shared)
        var helper = makeBinary(platform: 6)
        try MachOBinary.addLibrary(&helper, path: "@executable_path/../../Frameworks/Shared.dylib")
        _ = try write(helper, "PlugIns/Widget.appex/Widget", in: app)
        let independent = try write(dylib(), "Frameworks/GameOnly.dylib", in: app)
        try GameRuntimeDependencies.synchronize(in: app, mainExecutable: main, runtimePath: runtime)
        #expect(try Data(contentsOf: shared) == sharedBefore)
        #expect(try Data(contentsOf: transitive) == dylib())
        #expect(try MachOBinary.loadedLibraries(in: Data(contentsOf: independent)).last == runtime)
    }
}
#endif
