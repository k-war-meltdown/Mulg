#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import MachO
import Testing
@testable import MulgLibrary

@Suite("Runtime dependency ordinals")
struct DependencyOrdinalTests {
    private func command(_ type: UInt32, _ words: [UInt32]) -> Data {
        var data = Data()
        ([type, UInt32(8 + words.count * 4)] + words).forEach { data.appendUInt32($0) }
        return data
    }
    private func dependency(_ name: String) -> Data {
        var data = command(UInt32(LC_LOAD_DYLIB), [28, 0x1a74_1800, 0x20000, 0x10000, 0])
        data.append(contentsOf: name.utf8); data.append(0)
        while data.count % 8 != 0 { data.append(0) }
        data.setUInt32(UInt32(data.count), at: 4)
        return data
    }
    private func image(_ extra: [Data], payload: Data = Data(), libraries: [String] = ["runtime", "engine", "last"]) -> Data {
        let commands = libraries.map(dependency) + extra
        var data = Data()
        [MH_MAGIC_64, UInt32(bitPattern: CPU_TYPE_ARM64), 0, UInt32(MH_EXECUTE),
         UInt32(commands.count), UInt32(commands.reduce(0) { $0 + $1.count }), UInt32(MH_TWOLEVEL), 0]
            .forEach { data.appendUInt32($0) }
        commands.forEach { data.append($0) }
        data.append(Data(count: max(0, 512 - data.count))); data.append(payload)
        return data
    }
    private func edited(_ binary: Data, removing: [String] = ["runtime"], replacing: [String: String] = [:]) throws -> Data {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try binary.write(to: file)
        try MachOBinary.editLibraries(at: file, removing: removing, replacing: replacing)
        return try Data(contentsOf: file)
    }

    @Test func classicStreamsSymbolsAndAliasedReexportsKeepTheirProviders() throws {
        let bind = Data([0x12, 0x40, 120, 0, 0x90, 0x20, 0x83, 0, 0x90, 0x3f, 0x90, 0])
        let trie = Data([3, 8, 3, 0, 0]) // root reexports from library 3
        var symbol = Data(count: 16); symbol[4] = UInt8(N_UNDF); symbol[7] = 2
        let dyld = command(UInt32(LC_DYLD_INFO_ONLY), [0, 0, 512, UInt32(bind.count), 512, UInt32(bind.count),
            512, UInt32(bind.count), 512 + UInt32(bind.count), UInt32(trie.count)])
        let exports = command(UInt32(LC_DYLD_EXPORTS_TRIE), [512 + UInt32(bind.count), UInt32(trie.count)])
        let symbols = command(UInt32(LC_SYMTAB), [512 + UInt32(bind.count + trie.count), 1, 0, 0])
        let before = image([dyld, exports, symbols], payload: bind + trie + symbol)
        let after = try edited(before)
        #expect(try MachOBinary.loadedLibraries(in: after) == ["engine", "last"])
        #expect(after.count == before.count)
        #expect(after[512] == 0x11 && after[518] == 0x82 && after[519] == 0)
        #expect(after[522] == 0x90) // special ordinal and following bind stay intact
        #expect(after[512 + bind.count + 2] == 2)
        #expect(after[512 + bind.count + trie.count + 7] == 1)
    }

    @Test(arguments: [UInt32(1), 2, 3]) func chainedImportsRetainAddendsAndSpecialOrdinals(_ format: UInt32) throws {
        let width = format == 3 ? 16 : format == 2 ? 8 : 4
        var payload = Data(count: 28)
        payload.setUInt32(28, at: 8)
        payload.setUInt32(28 + UInt32(width * 3), at: 12)
        payload.setUInt32(3, at: 16); payload.setUInt32(format, at: 20)
        payload.append(Data(repeating: 0xa5, count: width * 3))
        for (index, ordinal) in [UInt16(2), 3, 0xffff].enumerated() {
            let at = 28 + index * width
            payload[at] = UInt8(ordinal & 255)
            if format == 3 { payload[at + 1] = UInt8(ordinal >> 8) }
        }
        let before = image([command(UInt32(LC_DYLD_CHAINED_FIXUPS), [512, UInt32(payload.count)])], payload: payload)
        let after = try edited(before)
        #expect(after[540] == 1 && after[540 + width] == 2 && after[540 + width * 2] == 255)
        for index in 0..<3 {
            let first = 540 + width * index + (format == 3 ? 2 : 1)
            #expect(after[first..<(540 + width * (index + 1))] == before[first..<(540 + width * (index + 1))])
        }
    }

    @Test(arguments: [UInt32(1), 2, 3]) func unsignedChainedOrdinalsAbove127AreRemapped(_ format: UInt32) throws {
        let width = format == 3 ? 16 : format == 2 ? 8 : 4
        var payload = Data(count: 28 + width)
        payload.setUInt32(28, at: 8); payload.setUInt32(1, at: 16); payload.setUInt32(format, at: 20)
        payload[28] = 150
        // Enough space before linkedit for the unusually long library list.
        var binary = image([], libraries: (0..<151).map { "lib\($0)" })
        var fixups = command(UInt32(LC_DYLD_CHAINED_FIXUPS), [0, UInt32(payload.count)])
        let oldCommands = Int(binary.uint32(at: 20))
        let offset = binary.count + fixups.count
        fixups.setUInt32(UInt32(offset), at: 8)
        binary.replaceSubrange((32 + oldCommands)..<(32 + oldCommands), with: fixups)
        binary.setUInt32(binary.uint32(at: 16) + 1, at: 16)
        binary.setUInt32(UInt32(oldCommands + fixups.count), at: 20)
        binary.append(payload)
        let after = try edited(binary, removing: ["lib0"])
        #expect(after[offset + 28] == 149)
    }

    @Test func replacementPreservesSlotFlagsVersionsAndAllPayloadBytes() throws {
        let stream = Data([0x11, 0x90, 0x12, 0x90, 0x13, 0x90, 0])
        let before = image([command(UInt32(LC_DYLD_INFO_ONLY), [0, 0, 512, UInt32(stream.count), 0, 0, 0, 0, 0, 0])], payload: stream)
        let after = try edited(before, removing: ["engine"], replacing: ["engine": "newRuntime"])
        #expect(try MachOBinary.loadedLibraries(in: after) == ["runtime", "newRuntime", "last"])
        #expect(after[512...] == before[512...])
        let dylibs = try MachOBinary.loadCommands(in: after).filter { $0.command == UInt32(LC_LOAD_DYLIB) }
        #expect(after[(dylibs[1].offset + 12)..<(dylibs[1].offset + 28)] == dependency("engine")[12..<28])
        let removedLast = try edited(image([]), removing: ["last"])
        #expect(try MachOBinary.loadedLibraries(in: removedLast) == ["runtime", "engine"])
    }

    @Test(arguments: [Data([0x11, 0x90, 0]), Data([0x20, 0x80]), Data([0xe0])])
    func unsafeRemovalLeavesFileUnchanged(_ stream: Data) throws {
        let before = image([command(UInt32(LC_DYLD_INFO_ONLY), [0, 0, 512, UInt32(stream.count), 0, 0, 0, 0, 0, 0])], payload: stream)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try before.write(to: file)
        #expect(throws: MachOBinary.Failure.self) { try MachOBinary.editLibraries(at: file, removing: ["runtime"]) }
        #expect(try Data(contentsOf: file) == before)
    }
}
#endif
