#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import MachO
import MulgContracts
import Testing
@testable import MulgLibrary

private func addingCommand(_ command: Data, to binary: Data) -> Data {
    var binary = binary
    let end = 32 + Int(binary.uint32(at: 20))
    binary.replaceSubrange(end..<(end + command.count), with: command)
    binary.setUInt32(binary.uint32(at: 16) + 1, at: 16)
    binary.setUInt32(binary.uint32(at: 20) + UInt32(command.count), at: 20)
    return binary
}

private func pathCommand(_ type: UInt32, _ path: String) -> Data {
    let fixed = type == UInt32(LC_RPATH) ? 12 : 24
    let size = (fixed + path.utf8.count + 1 + 7) / 8 * 8
    var data = Data()
    data.appendUInt32(type); data.appendUInt32(UInt32(size)); data.appendUInt32(UInt32(fixed))
    data.append(Data(count: fixed - data.count))
    data.append(contentsOf: path.utf8)
    data.append(Data(count: size - data.count))
    return data
}

@Suite("Wrapper dependency and metadata upgrades")
struct WrapperUpgradeTests {
    @Test func preservesNativePlatformsAndRejectsSimulatorConversion() throws {
        for platform in [UInt32(PLATFORM_MACOS), UInt32(PLATFORM_MACCATALYST)] {
            let source = makeBinary(platform: platform)
            #expect(try MachOBinary.convertForMac(source, keepSDK: false) == source)
        }
        var legacy = makeBinary()
        let build = try #require(try MachOBinary.loadCommands(in: legacy).first { $0.command == UInt32(LC_BUILD_VERSION) })
        legacy.setUInt32(UInt32(LC_VERSION_MIN_MACOSX), at: build.offset)
        legacy.setUInt32(MachOBinary.Version(13).packed, at: build.offset + 8)
        legacy.setUInt32(MachOBinary.Version(14).packed, at: build.offset + 12)
        #expect(try MachOBinary.convertForMac(legacy, keepSDK: false) == legacy)
        #expect(throws: MachOBinary.Failure.self) { try MachOBinary.convertForMac(makeBinary(platform: 7), keepSDK: true) }
    }

    @Test func repairsOnlyEmptyIOS100Placeholders() throws {
        var source = makeBinary(sdk: .init(26, 1))
        source.setUInt32(UInt32(MH_DYLIB), at: 12)
        let build = try #require(try MachOBinary.loadCommands(in: source).first { $0.command == UInt32(LC_BUILD_VERSION) })
        source.setUInt32(MachOBinary.Version(100).packed, at: build.offset + 12)
        let segment = try #require(try MachOBinary.loadCommands(in: source).first { $0.command == UInt32(LC_SEGMENT_64) })
        source.setUInt32(0x400, at: segment.offset + 48)
        source.setUInt32(0, at: segment.offset + 72 + 40)
        source.replaceSubrange(0x400..<source.count, with: Data(count: source.count - 0x400))
        let converted = try MachOBinary.convertForMac(source, keepSDK: true)
        #expect(try MachOBinary.buildInfo(of: converted)?.minimumOS == .init(27))
        #expect(try MachOBinary.buildInfo(of: converted)?.sdk == .init(26, 1))
        #expect(converted[0x400...] == source[0x400...])
        #expect(try MachOBinary.convertForMac(converted, keepSDK: true) == converted)
        for variant in 0..<4 {
            var real = source
            switch variant {
            case 0: real.setUInt32(16, at: segment.offset + 72 + 40)
            case 1: real.setUInt32(UInt32(MH_EXECUTE), at: 12)
            case 2: real.setUInt32(MachOBinary.Version(28).packed, at: build.offset + 16)
            default: real.setUInt32(MachOBinary.Version(28, 1).packed, at: build.offset + 12)
            }
            let expected = try MachOBinary.buildInfo(of: real)?.minimumOS
            #expect(try MachOBinary.buildInfo(of: MachOBinary.convertForMac(real, keepSDK: true))?.minimumOS == expected)
        }
        var occupied = source
        occupied[32 + Int(occupied.uint32(at: 20))] = 0xff
        #expect(throws: MachOBinary.Failure.noRoomForLoadCommands) {
            try MachOBinary.convertForMac(occupied, keepSDK: true)
        }
        let app = try InstallerTests().makeApp()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        try converted.write(to: app.appendingPathComponent("Game"))
        try DependencyValidation.validate(app: app, binaries: [], systemContains: { _ in true })
        var future = converted
        let futureBuild = try #require(try MachOBinary.loadCommands(in: future).first { $0.command == UInt32(LC_BUILD_VERSION) })
        future.setUInt32(MachOBinary.Version(28).packed, at: futureBuild.offset + 12)
        try future.write(to: app.appendingPathComponent("Game"))
        #expect(throws: DependencyValidation.Failure.self) {
            try DependencyValidation.validate(app: app, binaries: [], systemContains: { _ in true })
        }
    }
    @Test func embeddedExecutablesHaveTheirOwnDependencyContext() throws {
        let app = try InstallerTests().makeApp()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let files = FileManager.default
        let nested = app.appendingPathComponent("PlugIns/Widget.appex")
        try files.createDirectory(at: nested.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Widget"], format: .xml, options: 0)
            .write(to: nested.appendingPathComponent("Info.plist"))
        var binary = try MachOBinary.convertForMac(makeBinary(), keepSDK: true)
        try MachOBinary.replaceLibrary(&binary, from: "/System/iOSSupport/usr/lib/swift/libswiftUIKit.dylib", to: "@executable_path/Frameworks/SDK.dylib")
        let executable = nested.appendingPathComponent("Widget")
        try binary.write(to: executable)
        try MachOBinary.convertForMac(makeBinary(), keepSDK: true).write(to: nested.appendingPathComponent("Frameworks/SDK.dylib"))
        try MachOBinary.convertForMac(makeBinary(), keepSDK: true).write(to: app.appendingPathComponent("Game"))
        try DependencyValidation.validate(app: app, binaries: [executable], systemContains: { _ in true })
        try files.removeItem(at: nested.appendingPathComponent("Frameworks/SDK.dylib"))
        #expect(throws: DependencyValidation.Failure.self) { try DependencyValidation.validate(app: app, binaries: [executable], systemContains: { _ in true }) }
    }
    @Test func hostLibraryEditsPreserveUnicodePermissionsAndRejectOccupiedPadding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("游戏")
        try makeBinary().write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o751], ofItemAtPath: file.path)
        let path = "/Users/Érik/游戏/MulgRuntime.framework/MulgRuntime"
        try MachOBinary.editLibraries(at: file, adding: [path])
        #expect(try MachOBinary.loadedLibraries(in: Data(contentsOf: file)).contains(path))
        try MachOBinary.editLibraries(at: file, removing: [path])
        #expect(try !MachOBinary.loadedLibraries(in: Data(contentsOf: file)).contains(path))
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o751)
        var occupied = makeBinary()
        let end = 32 + Int(occupied.uint32(at: 20))
        occupied[end] = 0xff // Invalid UTF-8 is occupied data, never available header padding.
        try occupied.write(to: file)
        #expect(throws: MachOBinary.Failure.noRoomForLoadCommands) { try MachOBinary.editLibraries(at: file, adding: [path]) }
        #expect(try Data(contentsOf: file) == occupied)
    }
    @Test func deploymentRequirementsAndBuildToolsSurviveConversion() throws {
        let source = makeBinary()
        var body = Data()
        for entry in try MachOBinary.loadCommands(in: source) {
            var command = source.subdata(in: entry.offset..<(entry.offset + entry.size))
            if entry.command == UInt32(LC_BUILD_VERSION) {
                command.setUInt32(MachOBinary.Version(28, 1).packed, at: 12)
                command.setUInt32(32, at: 4); command.setUInt32(1, at: 20)
                command.appendUInt32(3); command.appendUInt32(0x0640_0000)
            }
            body.append(command)
        }
        var binary = source.prefix(32)
        binary.setUInt32(UInt32(body.count), at: 20)
        binary.append(body); binary.append(Data(count: 0x400 - binary.count)); binary.append(source[0x400...])
        try MachOBinary.convertToCatalyst(&binary, keepSDK: true)
        #expect(try MachOBinary.buildInfo(of: binary)?.minimumOS == .init(28, 1))
        let build = try #require(try MachOBinary.loadCommands(in: binary).first { $0.command == UInt32(LC_BUILD_VERSION) })
        #expect(binary.uint32(at: build.offset + 20) == 1)
        #expect(binary.uint32(at: build.offset + 24) == 3)
        #expect(binary[0x400...] == source[0x400...])
    }

    @Test func rejectsTruncatedThinHeadersAndPrefersOrdinaryARM64() throws {
        #expect(throws: MachOBinary.Failure.self) { try MachOBinary.arm64Slice(of: makeBinary().prefix(8)) }
        let ordinary = makeBinary()
        var pac = ordinary; pac.setUInt32(2, at: 8)
        let offset = UInt32(0x1000), second = UInt32(0x2000)
        var fat = bigEndian([FAT_MAGIC, 2, UInt32(bitPattern: CPU_TYPE_ARM64), 2, offset, UInt32(pac.count), 12,
                             UInt32(bitPattern: CPU_TYPE_ARM64), 0, second, UInt32(ordinary.count), 12])
        fat.append(Data(count: Int(offset) - fat.count)); fat.append(pac)
        fat.append(Data(count: Int(second) - fat.count)); fat.append(ordinary)
        #expect(try MachOBinary.arm64Slice(of: fat) == ordinary)
    }

    @Test func resolvesNestedRunpathsAndRejectsRequiredReexports() throws {
        let app = try InstallerTests().makeApp()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let main = app.appendingPathComponent("Game")
        let engine = app.appendingPathComponent("Frameworks/Engine.framework/Engine")
        var binary = try MachOBinary.convertForMac(makeBinary(), keepSDK: true)
        try MachOBinary.replaceLibrary(&binary, from: "/System/iOSSupport/usr/lib/swift/libswiftUIKit.dylib",
                                      to: "@rpath/Engine.framework/Engine")
        binary = addingCommand(pathCommand(UInt32(LC_RPATH), "@executable_path/Frameworks"), to: binary)
        try binary.write(to: main)
        var nested = try MachOBinary.convertForMac(makeBinary(), keepSDK: true)
        nested = addingCommand(pathCommand(UInt32(LC_LOAD_WEAK_DYLIB), "@loader_path/Optional.dylib"), to: nested)
        try nested.write(to: engine)
        try DependencyValidation.validate(app: app, binaries: [main, engine], systemContains: { _ in true })
        nested = addingCommand(pathCommand(UInt32(LC_REEXPORT_DYLIB), "@loader_path/Required.dylib"), to: nested)
        try nested.write(to: engine)
        #expect(throws: DependencyValidation.Failure.self) {
            try DependencyValidation.validate(app: app, binaries: [main, engine], systemContains: { _ in true })
        }
    }

    @Test func discoversExecutableExtensionsAndKeepsLaunchPermissions() async throws {
        let app = try InstallerTests().makeApp()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let library = app.appendingPathComponent("Frameworks/Engine.framework/Renderer.bin")
        try makeBinary().write(to: library)
        try FileManager.default.setAttributes([.posixPermissions: 0o751], ofItemAtPath: library.path)
        #expect(GameInstaller.findBinaries(in: app).contains { $0.resolvingSymlinksInPath() == library.resolvingSymlinksInPath() })
        try await GameInstaller.convertBinaries([library], keepSDK: true, runtimePath: nil,
                                               mainExecutable: app.appendingPathComponent("Game"))
        #expect((try FileManager.default.attributesOfItem(atPath: library.path)[.posixPermissions] as? NSNumber)?.intValue == 0o751)
    }

    @Test func signedNestedCapabilitiesAreCapturedBeforeRewriting() throws {
        let app = try InstallerTests().makeApp()
        let root = app.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let extensionURL = app.appendingPathComponent("PlugIns/Widget.appex")
        try FileManager.default.createDirectory(at: extensionURL, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.game.widget", "CFBundleExecutable": "Different.bin"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: extensionURL.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: extensionURL.appendingPathComponent("Different.bin"))
        let values: [String: Any] = ["com.apple.security.network.client": true,
                                   "com.apple.developer.icloud-container-identifiers": ["iCloud.example"]]
        let entitlements = root.appendingPathComponent("e.plist")
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: entitlements)
        try Command.run("/usr/bin/codesign", ["--force", "--sign", "-", "--entitlements", entitlements.path, extensionURL.path])
        let binaries = GameInstaller.findBinaries(in: app)
        let captured = try BundleCapabilities(app: app, binaries: binaries)
        let data = try #require(captured.entitlements.first { $0.key.resolvingSymlinksInPath() == extensionURL.resolvingSymlinksInPath() }?.value)
        let retained = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(retained["com.apple.security.network.client"] as? Bool == true)
        #expect(retained["com.apple.developer.icloud-container-identifiers"] == nil)
        #expect(captured.unavailable.contains { $0.contains("icloud-container-identifiers") })
        let plan = SigningPlan(app: app, binaries: binaries, entitlements: entitlements)
        #expect(plan.stages.joined().contains { $0.resolvingSymlinksInPath() == extensionURL.resolvingSymlinksInPath() })
        #expect(!plan.stages.joined().contains { $0.lastPathComponent == "Different.bin" })
    }

    @Test func contentAddressedRuntimesKeepTheirPreviousVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let framework = root.appendingPathComponent("MulgRuntime.framework")
        let bridge = root.appendingPathComponent("MulgBridge.bundle")
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bridge.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let executable = framework.appendingPathComponent("MulgRuntime")
        try makeBinary(platform: 6).write(to: executable)
        try makeBinary(platform: 1).write(to: bridge.appendingPathComponent("Contents/MacOS/MulgBridge"))
        try RuntimeManifest().write(to: framework.appendingPathComponent(RuntimeManifest.fileName))
        try RuntimeManifest().write(to: bridge.appendingPathComponent("Contents/Resources/" + RuntimeManifest.fileName))
        let first = try RuntimeInstaller.installVersion(bundled: framework, bridge: bridge, home: root)
        let old = try Data(contentsOf: first.appendingPathComponent("MulgRuntime"))
        var updated = old; updated[updated.count - 1] ^= 1
        try updated.write(to: executable)
        let second = try RuntimeInstaller.installVersion(bundled: framework, bridge: bridge, home: root)
        #expect(first != second)
        #expect(try Data(contentsOf: first.appendingPathComponent("MulgRuntime")) == old)
        #expect(try RuntimeInstaller.installVersion(bundled: framework, bridge: bridge, home: root) == second)
        #expect(RuntimeInstaller.isRuntimeLibrary(first.appendingPathComponent("MulgRuntime").path))
    }
}
#endif
