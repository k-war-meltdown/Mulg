// Host-side module: the Mulg app is a native macOS app, never Mac Catalyst.
#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import MachO
import MulgContracts
import Testing
@testable import MulgLibrary

/// A small arm64 executable in memory: one __TEXT section at 0x400, a build version
/// command, a libswiftUIKit load command and an encryption command.
func makeBinary(platform: UInt32 = UInt32(PLATFORM_IOS), sdk: MachOBinary.Version = .init(17, 2),
                cryptid: UInt32 = 0, sectionOffset: Int = 0x400) -> Data {
    var commands = Data()
    // segment_command_64 with one section_64
    commands.appendUInt32(UInt32(LC_SEGMENT_64)); commands.appendUInt32(72 + 80)
    commands.append(contentsOf: Array("__TEXT".utf8) + [UInt8](repeating: 0, count: 10))
    commands.append(Data(count: 32))                 // vmaddr, vmsize, fileoff, filesize
    commands.append(Data(count: 8))                  // maxprot, initprot
    commands.appendUInt32(1); commands.appendUInt32(0)
    commands.append(contentsOf: Array("__text".utf8) + [UInt8](repeating: 0, count: 10))
    commands.append(contentsOf: Array("__TEXT".utf8) + [UInt8](repeating: 0, count: 10))
    commands.append(Data(count: 8))                  // addr
    commands.append(contentsOf: [16, 0, 0, 0, 0, 0, 0, 0])  // size
    commands.appendUInt32(UInt32(sectionOffset))
    commands.append(Data(count: 28))
    // build_version_command
    commands.appendUInt32(UInt32(LC_BUILD_VERSION)); commands.appendUInt32(24)
    commands.appendUInt32(platform); commands.appendUInt32(MachOBinary.Version(15).packed)
    commands.appendUInt32(sdk.packed); commands.appendUInt32(0)
    // dylib_command
    let name = Array("@rpath/libswiftUIKit.dylib".utf8)
    let dylibSize = (24 + name.count + 1 + 7) / 8 * 8
    commands.appendUInt32(UInt32(LC_LOAD_DYLIB)); commands.appendUInt32(UInt32(dylibSize))
    commands.appendUInt32(24); commands.appendUInt32(2); commands.appendUInt32(0x10000); commands.appendUInt32(0x10000)
    commands.append(contentsOf: name)
    commands.append(Data(count: dylibSize - 24 - name.count))
    // encryption_info_command_64
    commands.appendUInt32(UInt32(LC_ENCRYPTION_INFO_64)); commands.appendUInt32(24)
    commands.appendUInt32(UInt32(sectionOffset)); commands.appendUInt32(16); commands.appendUInt32(cryptid); commands.appendUInt32(0)

    var binary = Data()
    binary.appendUInt32(MH_MAGIC_64)
    binary.appendUInt32(UInt32(bitPattern: CPU_TYPE_ARM64))
    binary.appendUInt32(0)
    binary.appendUInt32(UInt32(MH_EXECUTE))
    binary.appendUInt32(4)
    binary.appendUInt32(UInt32(commands.count))
    binary.appendUInt32(0); binary.appendUInt32(0)
    binary.append(commands)
    binary.append(Data(count: sectionOffset - binary.count))
    binary.append(Data(repeating: 0xAA, count: 16))
    return binary
}

func bigEndian(_ values: [UInt32]) -> Data {
    values.reduce(into: Data()) { data, value in data.appendUInt32(value.byteSwapped) }
}

@Suite struct MachOTests {
    @Test func readsBuildInfoAndLibraries() throws {
        let binary = makeBinary()
        let info = try #require(try MachOBinary.buildInfo(of: binary))
        #expect(info.platform == UInt32(PLATFORM_IOS))
        #expect(info.sdk == .init(17, 2))
        #expect(try MachOBinary.loadedLibraries(in: binary) == ["@rpath/libswiftUIKit.dylib"])
        #expect(try !MachOBinary.isEncrypted(binary))
        #expect(try MachOBinary.isEncrypted(makeBinary(cryptid: 1)))
    }

    @Test func convertsToCatalystWithDefaultOrGameSDK() throws {
        for (keep, sdk) in [(false, MachOBinary.defaultSDK), (true, MachOBinary.Version(17, 2))] {
            let converted = try MachOBinary.convertForMac(makeBinary(), keepSDK: keep)
            let info = try #require(try MachOBinary.buildInfo(of: converted))
            #expect(info.platform == UInt32(PLATFORM_MACCATALYST))
            #expect(info.minimumOS == MachOBinary.catalystMinimumOS)
            #expect(info.sdk == sdk)
            #expect(try MachOBinary.loadedLibraries(in: converted) == ["/System/iOSSupport/usr/lib/swift/libswiftUIKit.dylib"])
            // Section data is untouched.
            #expect(converted[0x400..<0x410] == Data(repeating: 0xAA, count: 16))
        }
    }

    @Test func addsRuntimeOnceAndRefusesWithoutRoom() throws {
        var binary = makeBinary()
        try MachOBinary.addLibrary(&binary, path: "/x/MulgRuntime")
        try MachOBinary.addLibrary(&binary, path: "/x/MulgRuntime")
        #expect(try MachOBinary.loadedLibraries(in: binary).filter { $0 == "/x/MulgRuntime" }.count == 1)

        let headerAndCommands = 32 + 152 + 24 + 56 + 24
        var tight = makeBinary(sectionOffset: headerAndCommands + 8)
        #expect(throws: MachOBinary.Failure.noRoomForLoadCommands) {
            try MachOBinary.addLibrary(&tight, path: "/x/MulgRuntime")
        }
    }

    @Test func refusesATruncatedLoadCommand() {
        var binary = makeBinary()
        // The encryption command is the last one; claim it is only 8 bytes long.
        let commandsEnd = 32 + Int(binary.uint32(at: 20))
        binary.setUInt32(8, at: commandsEnd - 24 + 4)
        binary.setUInt32(binary.uint32(at: 20) - 16, at: 20)
        #expect(throws: MachOBinary.Failure.corrupted("load command 3")) { try MachOBinary.isEncrypted(binary) }
    }

    @Test func rejectsLoadCommandGrowthPastAFileWithCorruptSectionOffset() {
        var binary = makeBinary()
        binary.setUInt32(4096, at: 32 + 72 + 48)
        #expect(throws: MachOBinary.Failure.self) {
            try MachOBinary.addLibrary(&binary, path: String(repeating: "x", count: 1200))
        }
    }

    @Test func thinsBothUniversalFormats() throws {
        let thin = makeBinary()
        let otherCPU = UInt32(bitPattern: CPU_TYPE_X86_64)
        let arm = UInt32(bitPattern: CPU_TYPE_ARM64)
        let offset: UInt32 = 0x1000
        var fat = bigEndian([FAT_MAGIC, 2, otherCPU, 0, offset, 4, 12, arm, 0, offset, UInt32(thin.count), 12])
        fat.append(Data(count: Int(offset) - fat.count)); fat.append(thin)
        var fat64 = bigEndian([FAT_MAGIC_64, 1, arm, 0, 0, offset, 0, UInt32(thin.count), 12, 0])
        fat64.append(Data(count: Int(offset) - fat64.count)); fat64.append(thin)

        for data in [thin, fat, fat64] {
            #expect(MachOBinary.isMachOHeader(data.prefix(4)))
            #expect(try MachOBinary.arm64Slice(of: data) == thin)
        }
        #expect(!MachOBinary.isMachOHeader(Data("PK\u{3}\u{4}".utf8)))
    }

    /// A real linker-made binary, not just the synthetic one.
    @Test func readsSystemBinary() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "/bin/ls"), options: .alwaysMapped)
        let slice = try MachOBinary.arm64Slice(of: data)
        #expect(try MachOBinary.buildInfo(of: slice)?.platform == UInt32(PLATFORM_MACOS))
        #expect(try MachOBinary.loadedLibraries(in: slice).contains("/usr/lib/libSystem.B.dylib"))
        var copy = slice
        try MachOBinary.convertToCatalyst(&copy, keepSDK: true)
        #expect(try MachOBinary.buildInfo(of: copy)?.platform == UInt32(PLATFORM_MACCATALYST))
        try MachOBinary.addLibrary(&copy, path: "/r/MulgRuntime")

        // codesign accepts the rewritten file.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try copy.write(to: file)
        try SigningPlan.codesign(["--force", "--sign", "-", file.path])
    }
}

@Suite struct InstallerTests {
    func makeApp(bundleIdentifier: String = "com.example.game") throws -> URL {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("Game.app")
        let framework = app.appendingPathComponent("Frameworks/Engine.framework")
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": bundleIdentifier, "CFBundleExecutable": "Game"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        try makeBinary().write(to: app.appendingPathComponent("Game"))
        try makeBinary().write(to: framework.appendingPathComponent("Engine"))
        try makeBinary().write(to: app.appendingPathComponent("Frameworks/libextra.dylib"))
        try Data("not code".utf8).write(to: app.appendingPathComponent("readme"))
        return app
    }

    @Test func signingPlanGoesInsideOut() {
        let app = URL(fileURLWithPath: "/A/Game.app")
        let binaries = ["Game", "Frameworks/Engine.framework/Engine", "Frameworks/libextra.dylib",
                        "PlugIns/Widget.appex/Widget", "PlugIns/Widget.appex/Frameworks/Inner.framework/Inner"]
            .map { app.appendingPathComponent($0) }
        let plan = SigningPlan(app: app, binaries: binaries, entitlements: URL(fileURLWithPath: "/e.plist"))
        #expect(plan.stages.map { $0.map(\.path) } == [
            ["/A/Game.app/PlugIns/Widget.appex/Frameworks/Inner.framework"],
            ["/A/Game.app/Frameworks/Engine.framework", "/A/Game.app/Frameworks/libextra.dylib",
             "/A/Game.app/PlugIns/Widget.appex"]
        ])
        #expect(plan.arguments(for: plan.app) == ["--force", "--sign", "-", "--entitlements", "/e.plist", "/A/Game.app"])
        #expect(!plan.arguments(for: plan.stages[0][0]).contains("--deep"))
    }

    @Test func installConvertsInjectsAndRecords() async throws {
        let app = try makeApp()
        let plugin = app.deletingLastPathComponent().appendingPathComponent("helper.dylib")
        try makeBinary().write(to: plugin)
        var settings = GameSettings(bundleIdentifier: "com.example.game")
        settings.mulg.engine.keepGameSDKVersion = true

        try await GameInstaller.install(
            app: app,
            options: .init(runtimePath: "/r/MulgRuntime", entitlements: URL(fileURLWithPath: "/e.plist"), plugins: [plugin],
                           category: GameInstaller.gamesCategory),
            settings: &settings,
            preflight: { _, _ in }, sign: { plan in #expect(plan.stages.joined().contains { $0.lastPathComponent == "helper.dylib" }) }
        )

        #expect(GameInstaller.findBinaries(in: app).count == 4)
        let main = try Data(contentsOf: app.appendingPathComponent("Game"))
        #expect(try MachOBinary.loadedLibraries(in: main).contains("/r/MulgRuntime"))
        #expect(try MachOBinary.buildInfo(of: main)?.sdk == .init(17, 2))
        let engine = try Data(contentsOf: app.appendingPathComponent("Frameworks/Engine.framework/Engine"))
        #expect(try !MachOBinary.loadedLibraries(in: engine).contains("/r/MulgRuntime"))
        #expect(try MachOBinary.buildInfo(of: engine)?.platform == UInt32(PLATFORM_MACCATALYST))
        #expect(settings.mulg.engine.trustedPluginHashes.keys.sorted() == ["helper.dylib", "helper.module.json"])
        #expect(settings.mulg.engine.trustedPluginHashes["helper.module.json"] == "absent")
        #expect(settings.mulg.engine.injectedRuntimeVersion == MulgVersion.current)
        #expect(settings.mulg.engine.injectedRuntimeProtocol == MulgVersion.runtimeProtocol)
        #expect(GameInstaller.category(of: app) == GameInstaller.gamesCategory)
    }

    @Test func refusesProhibitedAndEncryptedGames() async throws {
        var settings = GameSettings(bundleIdentifier: "x")
        let options = GameInstaller.Options(runtimePath: "/r", entitlements: URL(fileURLWithPath: "/e.plist"))
        let blocked = try makeApp(bundleIdentifier: "com.tencent.ig")
        await #expect(throws: GameInstaller.Failure.prohibited(bundleIdentifier: "com.tencent.ig")) {
            try await GameInstaller.install(app: blocked, options: options, settings: &settings, preflight: { _, _ in }, sign: { _ in })
        }
        let encrypted = try makeApp()
        try makeBinary(cryptid: 1).write(to: encrypted.appendingPathComponent("Game"))
        await #expect(throws: GameInstaller.Failure.encrypted(file: "Game")) {
            try await GameInstaller.install(app: encrypted, options: options, settings: &settings, preflight: { _, _ in }, sign: { _ in })
        }
    }

    @Test func refusesMissingMainExecutable() async throws {
        let app = try makeApp()
        let main = app.appendingPathComponent("Game")
        try FileManager.default.removeItem(at: main)
        var settings = GameSettings(bundleIdentifier: "com.example.game")
        let options = GameInstaller.Options(runtimePath: "/r", entitlements: URL(fileURLWithPath: "/e.plist"))
        await #expect(throws: GameInstaller.Failure.missingExecutable(main.path)) {
            try await GameInstaller.install(app: app, options: options, settings: &settings, preflight: { _, _ in }, sign: { _ in })
        }
        #expect(settings.mulg.engine.injectedRuntimeProtocol == nil)
    }

    @Test func installsMainExecutableWithExtension() async throws {
        let app = try makeApp()
        let main = app.appendingPathComponent("Game.bin")
        try FileManager.default.moveItem(at: app.appendingPathComponent("Game"), to: main)
        var info = try #require(GameInstaller.infoPlist(app))
        info["CFBundleExecutable"] = main.lastPathComponent
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        var settings = GameSettings(bundleIdentifier: "com.example.game")
        let options = GameInstaller.Options(runtimePath: "/r/MulgRuntime", entitlements: URL(fileURLWithPath: "/e.plist"))
        try await GameInstaller.install(app: app, options: options, settings: &settings, preflight: { _, _ in }, sign: { _ in })
        #expect(try MachOBinary.loadedLibraries(in: Data(contentsOf: main)).contains("/r/MulgRuntime"))
    }

    @Test func hostCanInjectAfterConversionBeforeSigning() async throws {
        let app = try makeApp(bundleIdentifier: "com.tencent.ig")
        let main = app.appendingPathComponent("Game")
        var settings = GameSettings(bundleIdentifier: "com.tencent.ig")
        try await GameInstaller.install(
            app: app,
            options: .init(runtimePath: nil, entitlements: URL(fileURLWithPath: "/e.plist"),
                           allowProhibited: true),
            settings: &settings,
            prepare: { _ in
                var binary = try Data(contentsOf: main)
                #expect(try MachOBinary.buildInfo(of: binary)?.platform == UInt32(PLATFORM_MACCATALYST))
                try MachOBinary.addLibrary(&binary, path: "/r/host-runtime")
                try binary.write(to: main)
            },
            preflight: { _, _ in }, sign: { _ in
                let libraries = try MachOBinary.loadedLibraries(in: Data(contentsOf: main))
                #expect(libraries.contains("/r/host-runtime"))
            })
        #expect(settings.mulg.engine.injectedRuntimeVersion == nil)
    }

    @Test func updateKeepsOldAppOnFailureAndExternalLocationOnSuccess() throws {
        enum Rejected: Error, Equatable { case signature }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Library")
        let games = root.appendingPathComponent("Games")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: games, withIntermediateDirectories: true)
        let installed = games.appendingPathComponent("com.example.game.app")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: installed.appendingPathComponent("marker"))
        let link = library.appendingPathComponent(installed.lastPathComponent)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: installed)
        let update = try makeApp()

        #expect(throws: Rejected.signature) {
            try GameInstaller.place(update, bundleIdentifier: "com.example.game", in: library, library: library,
                                    leasePaths: ContainerPaths(home: root),
                                    verify: { _ in throw Rejected.signature })
        }
        #expect(try String(contentsOf: installed.appendingPathComponent("marker"), encoding: .utf8) == "old")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == installed.path)

        let result = try GameInstaller.place(update, bundleIdentifier: "com.example.game", in: library,
                                             library: library, leasePaths: ContainerPaths(home: root), verify: { _ in })
        #expect(result.standardizedFileURL.path == installed.standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent("Game").path))
        #expect(!FileManager.default.fileExists(atPath: installed.appendingPathComponent("marker").path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == installed.path)
    }
}
#endif
