#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import MachO
import Testing
@testable import MulgLibrary

@Suite("Explicit game storage providers")
struct StorageImportProvidersTests {
    private let runtime = "/tmp/MulgRuntime.framework/MulgRuntime"
    private let foundation = "/System/Library/Frameworks/Foundation.framework/Foundation"
    private let security = "/System/Library/Frameworks/Security.framework/Security"
    private let search = "_NSSearchPathForDirectoriesInDomains"

    private func word64(_ value: UInt64, in data: inout Data, at offset: Int) {
        Swift.withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(offset..<(offset + 8), with: $0) }
    }
    private func library(_ path: String) -> Data {
        let size = (24 + path.utf8.count + 1 + 7) / 8 * 8
        var data = Data()
        for word in [UInt32(LC_LOAD_DYLIB), UInt32(size), 24, 2, 0x10000, 0x10000] { data.appendUInt32(word) }
        data.append(contentsOf: path.utf8); data.append(Data(count: size - data.count))
        return data
    }
    private func image(_ payload: Data, commands extra: [Data], paddingLibraries: Int = 0) -> Data {
        var text = Data(count: 152), linkedit = Data(count: 72), build = Data()
        text.setUInt32(UInt32(LC_SEGMENT_64), at: 0); text.setUInt32(152, at: 4)
        text.replaceSubrange(8..<14, with: Data("__TEXT".utf8))
        word64(0x4000, in: &text, at: 32); word64(0x2000, in: &text, at: 48)
        text.setUInt32(1, at: 64)
        text.replaceSubrange(72..<78, with: Data("__text".utf8))
        text.replaceSubrange(88..<94, with: Data("__TEXT".utf8))
        word64(0x1000, in: &text, at: 104); word64(16, in: &text, at: 112)
        text.setUInt32(0x1000, at: 120)
        linkedit.setUInt32(UInt32(LC_SEGMENT_64), at: 0); linkedit.setUInt32(72, at: 4)
        linkedit.replaceSubrange(8..<18, with: Data("__LINKEDIT".utf8))
        word64(0x4000, in: &linkedit, at: 24); word64(0x4000, in: &linkedit, at: 32)
        word64(0x2000, in: &linkedit, at: 40); word64(UInt64(payload.count), in: &linkedit, at: 48)
        for word in [UInt32(LC_BUILD_VERSION), 24, UInt32(PLATFORM_MACCATALYST), 0x1b0000, 0x1b0000, 0] { build.appendUInt32(word) }
        let libraries = [library(foundation), library("/usr/lib/libSystem.B.dylib"), library("@rpath/Custom.dylib")]
            + (0..<paddingLibraries).map { library("@rpath/Extra\($0).dylib") } + [library(runtime)]
        let commands = [text, linkedit, build] + libraries + extra
        var data = Data()
        for word in [MH_MAGIC_64, UInt32(bitPattern: CPU_TYPE_ARM64), 0, UInt32(MH_DYLIB),
                     UInt32(commands.count), UInt32(commands.reduce(0) { $0 + $1.count }), UInt32(MH_TWOLEVEL), 0] {
            data.appendUInt32(word)
        }
        commands.forEach { data.append($0) }
        data.append(Data(count: 0x2000 - data.count))
        data.replaceSubrange(0x1000..<0x1010, with: Data(repeating: 0xa5, count: 16))
        data.append(payload)
        return data
    }

    @Test(arguments: [UInt32(1), 2, 3], ["_NSSearchPathForDirectoriesInDomains", "_open", "_stat", "_access", "_rename", "_unlink", "_mkdir", "_rmdir", "_lstat", "_opendir", "_fopen", "_statfs", "_statvfs", "_sysctl", "_sysctlbyname", "_gethostname"])
    func chainedAndSymbolProvidersAgreeWithoutTouchingOtherImports(format: UInt32, search: String) throws {
        let nativeOrdinal = search == self.search ? 1 : 2
        let width = format == 3 ? 16 : (format == 2 ? 8 : 4)
        let names = Data((search + "\0_NSLog\0").utf8)
        var payload = Data()
        for word in [UInt32(0), 0, 28, UInt32(28 + 3 * width), 3, format, 0] { payload.appendUInt32(word) }
        for (ordinal, offset) in [(nativeOrdinal, 0), (1, search.utf8.count + 1), (3, 0)] {
            if format == 3 {
                let begin = payload.count; payload.append(Data(count: 16))
                word64(UInt64(ordinal) | 0x10000 | UInt64(offset) << 32, in: &payload, at: begin)
                word64(0x123456789abcdef0, in: &payload, at: begin + 8)
            } else {
                payload.appendUInt32(UInt32(ordinal) | 0x100 | UInt32(offset) << 9)
                if format == 2 { payload.appendUInt32(0x12345678) }
            }
        }
        payload.append(names)
        let chainSize = payload.count
        while payload.count < 0x100 { payload.append(0) }
        let table = payload.count
        for ordinal in [nativeOrdinal, 3] {
            payload.appendUInt32(1); payload.append(contentsOf: [UInt8(N_EXT), 0, 0x20, UInt8(ordinal)])
            payload.append(Data(count: 8))
        }
        let strings = payload.count; payload.append(0); payload.append(Data((search + "\0").utf8))
        var chained = Data(), symtab = Data()
        for word in [UInt32(LC_DYLD_CHAINED_FIXUPS), 16, 0x2000, UInt32(chainSize)] { chained.appendUInt32(word) }
        for word in [UInt32(LC_SYMTAB), 24, UInt32(0x2000 + table), 2, UInt32(0x2000 + strings), UInt32(payload.count - strings)] { symtab.appendUInt32(word) }
        var binary = image(payload, commands: [chained, symtab]), original = binary
        #expect(try MachOBinary.routeStorageImports(&binary, runtimePath: runtime))
        #expect(binary[0x2000 + 28] == 4)
        #expect(binary[0x2000 + 28 + width] == 1) // unrelated Foundation function
        #expect(binary[0x2000 + 28 + 2 * width] == 3) // SDK-owned function with the same name
        #expect(binary[0x2000 + table + 7] == 4 && binary[0x2000 + table + 23] == 3)
        var expected = original
        expected[0x2000 + 28] = 4; expected[0x2000 + table + 7] = 4
        #expect(binary == expected) // weak flags, addends, code and all other payload bytes unchanged
        let routed = binary
        #expect(try !MachOBinary.routeStorageImports(&binary, runtimePath: runtime))
        #expect(binary == routed)
        #expect(try MachOBinary.routeStorageImports(&binary, runtimePath: nil))
        #expect(binary == original)
    }

    @Test(arguments: ["_SecItemCopyMatching", "_SecItemAdd", "_SecItemUpdate", "_SecItemDelete",
                      "_SecKeyCreateRandomKey", "_SecKeyGeneratePair"])
    func gameCredentialImportsUseVirtualKeychainAndRestoreOnlyOnRemoval(symbol: String) throws {
        var payload = Data()
        for word in [UInt32(0), 0, 28, 32, 1, 1, 0, 5 | UInt32(0x100)] { payload.appendUInt32(word) }
        payload.append(Data((symbol + "\0").utf8))
        var chained = Data()
        for word in [UInt32(LC_DYLD_CHAINED_FIXUPS), 16, 0x2000, UInt32(payload.count)] { chained.appendUInt32(word) }
        var binary = image(payload, commands: [library(security), chained])
        let original = binary
        #expect(try MachOBinary.routeStorageImports(&binary, runtimePath: runtime))
        #expect(binary[0x2000 + 28] == 4) // MulgRuntime, never Apple Security in the installed game
        #expect(try !MachOBinary.routeStorageImports(&binary, runtimePath: runtime))
        #expect(try MachOBinary.routeStorageImports(&binary, runtimePath: nil))
        #expect(binary == original) // Apple Security is restored only when MulgRuntime is removed
    }

    @Test func legacyStreamsSupportLargeOrdinalsKeepSignatureLastAndAreIdempotent() throws {
        var stream = Data([0x11, 0x40]); stream.append(Data((search + "\0").utf8))
        stream.append(contentsOf: [0x51, 0x70, 0, 0x90, 0x40]); stream.append(Data("_NSLog\0".utf8))
        stream.append(contentsOf: [0x90, 0])
        let seal = Data(repeating: 0xc7, count: 16)
        var payload = stream; payload.append(seal)
        var info = Data(count: 48), signature = Data()
        info.setUInt32(UInt32(LC_DYLD_INFO_ONLY), at: 0); info.setUInt32(48, at: 4)
        info.setUInt32(0x2000, at: 16); info.setUInt32(UInt32(stream.count), at: 20)
        for word in [UInt32(LC_CODE_SIGNATURE), 16, UInt32(0x2000 + stream.count), 16] { signature.appendUInt32(word) }
        var binary = image(payload, commands: [info, signature], paddingLibraries: 14)
        let code = binary.subdata(in: 0x1000..<0x1010)
        #expect(try MachOBinary.routeStorageImports(&binary, runtimePath: runtime))
        let commands = try MachOBinary.loadCommands(in: binary)
        let bind = try #require(commands.first { $0.command == UInt32(LC_DYLD_INFO_ONLY) })
        let offset = Int(binary.uint32(at: bind.offset + 16)), size = Int(binary.uint32(at: bind.offset + 20))
        let bytes = binary.subdata(in: offset..<(offset + size))
        #expect(bytes.range(of: Data([0x20, 18, 0x90])) != nil)
        #expect(bytes.range(of: Data([0x20, 1, 0x90])) != nil)
        let sig = try #require(commands.first { $0.command == UInt32(LC_CODE_SIGNATURE) })
        #expect(Int(binary.uint32(at: sig.offset + 8)) + 16 == binary.count)
        #expect(binary.suffix(16) == seal)
        #expect(binary.subdata(in: 0x1000..<0x1010) == code)
        let routed = binary
        #expect(try !MachOBinary.routeStorageImports(&binary, runtimePath: runtime))
        #expect(binary == routed)
        #expect(try MachOBinary.routeStorageImports(&binary, runtimePath: nil))
        #expect(try !MachOBinary.routeStorageImports(&binary, runtimePath: nil))
    }

    private let lazySymbols = ["_open", "_malloc", "_free", "_NSSearchPathForDirectoriesInDomains", "_NSLog", "_open"]

    private func lazyImage(paddingLibraries: Int, bti: Bool) throws -> (Data, [Int], [Int]) {
        var stream = Data(), entries: [Int] = []
        for (index, symbol) in lazySymbols.enumerated() {
            entries.append(stream.count)
            let ordinal = index == 5 ? 3 : (index == 3 || index == 4 ? 1 : 2)
            stream.append(contentsOf: [0x72, UInt8(index * 8), 0x10 | UInt8(ordinal), 0x40])
            stream.append(Data((symbol + "\0").utf8)); stream.append(contentsOf: [0x90, 0])
        }
        var info = Data(count: 48), data = Data(count: 72), signature = Data()
        info.setUInt32(UInt32(LC_DYLD_INFO_ONLY), at: 0); info.setUInt32(48, at: 4)
        info.setUInt32(0x2000, at: 32); info.setUInt32(UInt32(stream.count), at: 36)
        data.setUInt32(UInt32(LC_SEGMENT_64), at: 0); data.setUInt32(72, at: 4)
        data.replaceSubrange(8..<14, with: Data("__DATA".utf8))
        word64(0x8000, in: &data, at: 24); word64(0x1000, in: &data, at: 32)
        word64(0x1800, in: &data, at: 40); word64(0x100, in: &data, at: 48)
        data.setUInt32(3, at: 56); data.setUInt32(3, at: 60)
        for word in [UInt32(LC_CODE_SIGNATURE), 16, UInt32(0x2000 + stream.count), 16] { signature.appendUInt32(word) }
        var payload = stream; payload.append(Data(repeating: 0xc7, count: 16))
        var binary = image(payload, commands: [data, info, signature], paddingLibraries: paddingLibraries)
        let text = try #require(MachOBinary.loadCommands(in: binary).first { $0.command == UInt32(LC_SEGMENT_64) })
        word64(0x1800, in: &binary, at: text.offset + 48)
        binary.setUInt32(5, at: text.offset + 60)
        var name = Data("__stub_helper".utf8); name.append(Data(count: 16 - name.count))
        binary.replaceSubrange((text.offset + 72)..<(text.offset + 88), with: name)
        let stride = bti ? 16 : 12
        word64(UInt64(24 + lazySymbols.count * stride), in: &binary, at: text.offset + 112)
        var literals: [Int] = []
        for index in lazySymbols.indices {
            let helper = 0x1018 + index * stride, instruction = helper + (bti ? 4 : 0)
            if bti { binary.setUInt32(0xd503245f, at: helper) }
            binary.setUInt32(0x18000050, at: instruction)
            let branch = UInt32(bitPattern: Int32((0x1000 - (instruction + 4)) / 4)) & 0x03ffffff
            binary.setUInt32(0x14000000 | branch, at: instruction + 4)
            binary.setUInt32(UInt32(entries[index]), at: instruction + 8)
            literals.append(instruction + 8)
            word64(UInt64(helper), in: &binary, at: 0x1800 + index * 8)
        }
        binary.replaceSubrange(0x1200..<0x1210, with: Data(repeating: 0x5a, count: 16))
        return (binary, entries, literals)
    }

    /// Read from the helper's entry point, as a lazy binder would, rather than just
    /// checking that the complete rewritten stream contains the expected symbol.
    private enum LazyProbeError: Error { case malformed }

    private func lazyRecord(_ binary: Data, entry: Int) throws -> (String, Int, Int) {
        let info = try #require(MachOBinary.loadCommands(in: binary).first { $0.command == UInt32(LC_DYLD_INFO_ONLY) })
        let start = Int(binary.uint32(at: info.offset + 32)), end = start + Int(binary.uint32(at: info.offset + 36))
        var cursor = start + entry, symbol = "", ordinal = 0, displacement = -1
        func leb() throws -> Int {
            var result = 0, shift = 0
            repeat {
                guard cursor < end, shift < 56 else { throw LazyProbeError.malformed }
                let byte = binary[cursor]; cursor += 1
                result |= Int(byte & 127) << shift
                if byte < 128 { return result }
                shift += 7
            } while true
        }
        while cursor < end {
            let opcode = binary[cursor]; cursor += 1
            switch opcode & 0xf0 {
            case 0x10: ordinal = Int(opcode & 15)
            case 0x20: ordinal = try leb()
            case 0x40:
                let begin = cursor
                while cursor < end && binary[cursor] != 0 { cursor += 1 }
                guard cursor < end else { throw LazyProbeError.malformed }
                symbol = String(decoding: binary[begin..<cursor], as: UTF8.self); cursor += 1
            case 0x70:
                guard opcode & 15 == 2 else { throw LazyProbeError.malformed }
                displacement = try leb()
            case 0x90: return (symbol, ordinal, displacement)
            default: throw LazyProbeError.malformed
            }
        }
        throw LazyProbeError.malformed
    }

    @Test(arguments: [0, 14], [false, true])
    func lazyHelpersFollowRoutedRecordsAndNativeRestoration(paddingLibraries: Int, bti: Bool) throws {
        var (binary, _, literals) = try lazyImage(paddingLibraries: paddingLibraries, bti: bti)
        let before = binary
        #expect(try MachOBinary.routeStorageImports(&binary, runtimePath: runtime))
        for index in lazySymbols.indices {
            let (symbol, ordinal, displacement) = try lazyRecord(binary, entry: Int(binary.uint32(at: literals[index])))
            #expect(symbol == lazySymbols[index] && displacement == index * 8)
            let expected = index == 0 || index == 3 ? 4 + paddingLibraries : (index == 5 ? 3 : (index == 4 ? 1 : 2))
            #expect(ordinal == expected) // malloc/free and SDK-owned names retain their providers.
            #expect(binary.subdata(in: (literals[index] - 8)..<literals[index]) == before.subdata(in: (literals[index] - 8)..<literals[index]))
        }
        #expect(binary.subdata(in: 0x1200..<0x1210) == before.subdata(in: 0x1200..<0x1210))
        #expect(binary.suffix(16) == before.suffix(16))
        let routed = binary
        #expect(try !MachOBinary.routeStorageImports(&binary, runtimePath: runtime))
        #expect(binary == routed)
        #expect(try MachOBinary.routeStorageImports(&binary, runtimePath: nil))
        for index in lazySymbols.indices {
            let (symbol, ordinal, displacement) = try lazyRecord(binary, entry: Int(binary.uint32(at: literals[index])))
            #expect(symbol == lazySymbols[index] && displacement == index * 8)
            #expect(ordinal == (index == 5 ? 3 : (index == 3 || index == 4 ? 1 : 2)))
        }
        let restored = binary
        #expect(try !MachOBinary.routeStorageImports(&binary, runtimePath: nil))
        #expect(binary == restored)
    }

    @Test func refreshRepairsPreviouslyRoutedLazyHelpersWithoutRewritingProviders() throws {
        var (binary, entries, literals) = try lazyImage(paddingLibraries: 14, bti: false)
        #expect(try MachOBinary.routeStorageImports(&binary, runtimePath: runtime))
        for index in literals.indices { binary.setUInt32(UInt32(entries[index]), at: literals[index]) }
        #expect(throws: LazyProbeError.self) { try lazyRecord(binary, entry: Int(binary.uint32(at: literals[1]))) }
        let info = try #require(MachOBinary.loadCommands(in: binary).first { $0.command == UInt32(LC_DYLD_INFO_ONLY) })
        let stream = binary.uint32(at: info.offset + 32)
        #expect(try MachOBinary.routeStorageImports(&binary, runtimePath: runtime))
        #expect(binary.uint32(at: info.offset + 32) == stream)
        for index in literals.indices {
            #expect(try lazyRecord(binary, entry: Int(binary.uint32(at: literals[index]))).0 == lazySymbols[index])
        }
        #expect(try !MachOBinary.routeStorageImports(&binary, runtimePath: runtime))
    }

    @Test func malformedLazyHelperDoesNotPublishEarlierLiteralEdits() throws {
        var (binary, _, literals) = try lazyImage(paddingLibraries: 0, bti: false)
        binary.setUInt32(0xdeadbeef, at: literals[2] - 8)
        let before = binary
        #expect(throws: MachOBinary.Failure.self) { try MachOBinary.routeStorageImports(&binary, runtimePath: runtime) }
        #expect(binary == before)
    }

    @Test(arguments: [0, 1, 2])
    func malformedLazyMetadataDoesNotPublishPartialRepairs(kind: Int) throws {
        var (binary, _, _) = try lazyImage(paddingLibraries: 0, bti: false)
        let info = try #require(MachOBinary.loadCommands(in: binary).first { $0.command == UInt32(LC_DYLD_INFO_ONLY) })
        switch kind {
        case 0: binary[Int(binary.uint32(at: info.offset + 32))] = 0x7f // Invalid segment ordinal.
        case 1: binary.setUInt32(binary.uint32(at: info.offset + 36) - 1, at: info.offset + 36) // Missing final DONE.
        default: word64(binary.uint64(at: 0x1800), in: &binary, at: 0x1808) // Different records sharing one literal.
        }
        let before = binary
        #expect(throws: MachOBinary.Failure.self) { try MachOBinary.routeStorageImports(&binary, runtimePath: runtime) }
        #expect(binary == before)
    }

    @Test func brokenSystemFrameworkAliasUsesVerifiedVersionAndPreservesWeakLink() throws {
        let old = "/System/Library/Frameworks/Example.framework/Example"
        let fixed = "/System/iOSSupport/System/Library/Frameworks/Example.framework/Versions/B/Example"
        var dependency = library(old)
        dependency.setUInt32(UInt32(LC_LOAD_WEAK_DYLIB), at: 0)
        var binary = image(Data(), commands: [dependency])
        let before = binary
        #expect(try !MachOBinary.repairSystemFrameworkPaths(&binary,
            isLoadable: { _ in false }, currentVersion: { _ in "B" }))
        #expect(binary == before)
        #expect(try !MachOBinary.repairSystemFrameworkPaths(&binary,
            isLoadable: { $0 == old || $0 == fixed }, currentVersion: { _ in "B" }))
        #expect(try MachOBinary.repairSystemFrameworkPaths(&binary,
            isLoadable: { $0 == fixed }, currentVersion: { _ in "B" }))
        let dependencies = try MachOBinary.dependencies(in: binary)
        #expect(dependencies.last?.path == fixed && dependencies.last?.weak == true)
        #expect(try MachOBinary.loadedLibraries(in: binary).dropLast() == MachOBinary.loadedLibraries(in: before).dropLast())
        #expect(binary.subdata(in: 0x1000..<0x1010) == before.subdata(in: 0x1000..<0x1010))
        #expect(try !MachOBinary.repairSystemFrameworkPaths(&binary,
            isLoadable: { $0 == fixed }, currentVersion: { _ in "B" }))
    }

    @Test func malformedImportDoesNotPublishPartialEdits() throws {
        var payload = Data()
        for word in [UInt32(0), 0, 28, 32, 1, 1, 0, 0xffffff01] { payload.appendUInt32(word) }
        payload.append(0)
        var command = Data()
        for word in [UInt32(LC_DYLD_CHAINED_FIXUPS), 16, 0x2000, UInt32(payload.count)] { command.appendUInt32(word) }
        var binary = image(payload, commands: [command]); let before = binary
        #expect(throws: MachOBinary.Failure.self) { try MachOBinary.routeStorageImports(&binary, runtimePath: runtime) }
        #expect(binary == before)
    }
}
#endif
