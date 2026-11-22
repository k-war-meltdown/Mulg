#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import MachO
import MulgContracts
import Testing
@testable import MulgLibrary

private func imageWithCommands(_ commands: [Data]) -> Data {
    var data = Data()
    for value in [MH_MAGIC_64, UInt32(bitPattern: CPU_TYPE_ARM64), 0, UInt32(MH_DYLIB),
                  UInt32(commands.count), UInt32(commands.reduce(0) { $0 + $1.count }), 0, 0] {
        data.appendUInt32(value)
    }
    commands.forEach { data.append($0) }
    data.append(Data(count: 256))
    return data
}

private func modernDependency(flags: UInt32, path: String = "@rpath/Optional.dylib") -> Data {
    let size = (28 + path.utf8.count + 1 + 7) / 8 * 8
    var data = Data()
    for value in [UInt32(LC_LOAD_DYLIB), UInt32(size), 28, 0x1a74_1800, 0x20000, 0x10000, flags] {
        data.appendUInt32(value)
    }
    data.append(contentsOf: path.utf8)
    data.append(Data(count: size - data.count))
    return data
}

@Suite("Modern dependencies and protected Mach-O payloads")
struct MachOPayloadTests {
    @Test func modernFlagsAndVersionsSurviveUnicodePathReplacement() throws {
        let command = modernDependency(flags: 15)
        var binary = imageWithCommands([command])
        #expect(try MachOImage.dependencies(in: binary).first?.weak == true)
        let path = "/Users/Érik/游戏/Optional.dylib"
        try MachOBinary.replaceLibrary(&binary, from: "@rpath/Optional.dylib", to: path)
        #expect(try MachOImage.dependencies(in: binary).first?.path == path)
        #expect(try MachOImage.dependencies(in: binary).first?.weak == true)
        #expect(binary.uint32(at: 40) == 28)
        #expect(binary[44..<60] == command[12..<28])
        #expect(try MachOImage.dependencies(in: imageWithCommands([modernDependency(flags: 14)])).first?.weak == false)
        var legacy = makeBinary()
        try MachOBinary.replaceLibrary(&legacy, from: "@rpath/libswiftUIKit.dylib", to: path)
        #expect(try MachOBinary.loadedLibraries(in: legacy) == [path])
        #expect(try MachOBinary.dependencies(in: legacy).first?.weak == false)
    }

    @Test func modernMissingWeakDependencyRemainsOptionalInHostPreflight() throws {
        let app = try InstallerTests().makeApp()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let executable = app.appendingPathComponent("Game")
        try imageWithCommands([modernDependency(flags: 1)]).write(to: executable)
        try DependencyValidation.validate(app: app, binaries: [], systemContains: { _ in false })
        try imageWithCommands([modernDependency(flags: 0)]).write(to: executable)
        #expect(throws: DependencyValidation.Failure.self) {
            try DependencyValidation.validate(app: app, binaries: [], systemContains: { _ in false })
        }
    }

    @Test func malformedModernCommandsFailWithoutMutation() throws {
        var command = modernDependency(flags: 1)
        command.setUInt32(24, at: 8)
        var binary = imageWithCommands([command]), before = binary
        #expect(throws: MachOImage.Failure.self) { try MachOImage.dependencies(in: binary) }
        #expect(throws: MachOBinary.Failure.self) { try MachOBinary.addLibrary(&binary, path: "/x/runtime") }
        #expect(binary == before)
        command = command.prefix(24); command.setUInt32(24, at: 4)
        binary = imageWithCommands([command]); before = binary
        #expect(throws: MachOBinary.Failure.self) { try MachOBinary.addLibrary(&binary, path: "/x/runtime") }
        #expect(binary == before)
    }

    @Test(arguments: [UInt32(LC_FUNCTION_STARTS), UInt32(LC_CODE_SIGNATURE), UInt32(LC_DATA_IN_CODE),
                      UInt32(LC_DYLD_CHAINED_FIXUPS), UInt32(LC_DYLD_EXPORTS_TRIE), UInt32(LC_ATOM_INFO),
                      UInt32(LC_FUNCTION_VARIANTS), UInt32(LC_FUNCTION_VARIANT_FIXUPS)])
    func zeroLinkeditBytesAreOccupied(_ type: UInt32) throws {
        var command = Data()
        for word in [type, 16, 48, 64] { command.appendUInt32(word) }
        var binary = imageWithCommands([command])
        let before = binary
        #expect(throws: MachOBinary.Failure.noRoomForLoadCommands) { try MachOBinary.addLibrary(&binary, path: "/x/runtime") }
        #expect(binary == before)
        // Actual padding before the exact same payload is usable.
        binary.setUInt32(176, at: 40)
        try MachOBinary.addLibrary(&binary, path: "/x/runtime")
        #expect(binary[176..<240].allSatisfy { $0 == 0 })
    }

    @Test func segmentsSymbolsRelocationsAndNotesBoundGrowth() throws {
        var commands: [Data] = []
        for (type, size, offsetField, sizeField, stride) in [
            (UInt32(LC_SEGMENT_64), 72, 40, 48, 16),
            (UInt32(LC_SYMTAB), 24, 8, 12, 1),
            (UInt32(LC_DYSYMTAB), 80, 56, 60, 1),
            (UInt32(LC_DYLD_INFO_ONLY), 48, 8, 12, 16),
            (UInt32(LC_NOTE), 40, 24, 32, 16)] {
            var command = Data(count: size)
            command.setUInt32(type, at: 0); command.setUInt32(UInt32(size), at: 4)
            command.setUInt32(UInt32(32 + size), at: offsetField)
            command.setUInt32(UInt32(stride), at: sizeField)
            commands.append(command)
        }
        for command in commands {
            var binary = imageWithCommands([command])
            let before = binary
            #expect(throws: MachOBinary.Failure.noRoomForLoadCommands) { try MachOBinary.addLibrary(&binary, path: "/x/runtime") }
            #expect(binary == before)
        }
        var binary = makeBinary()
        binary.setUInt32(UInt32(32 + Int(binary.uint32(at: 20))), at: 32 + 72 + 56)
        binary.setUInt32(1, at: 32 + 72 + 60)
        let before = binary
        #expect(throws: MachOBinary.Failure.noRoomForLoadCommands) { try MachOBinary.addLibrary(&binary, path: "/x/runtime") }
        #expect(binary == before)
    }

    @Test func malformedSectionTablesRangesAndCommandTotalsAreRejected() {
        for field in [32 + 64, 32 + 72 + 48, 32 + 72 + 60, 20] {
            var binary = makeBinary()
            binary.setUInt32(UInt32.max, at: field)
            let before = binary
            #expect(throws: MachOBinary.Failure.self) { try MachOBinary.addLibrary(&binary, path: "/x/runtime") }
            #expect(binary == before)
        }
    }
}
#endif
