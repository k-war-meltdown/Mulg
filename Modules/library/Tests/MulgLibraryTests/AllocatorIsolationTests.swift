#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import MachO
import Testing
@testable import MulgLibrary

@Suite("Game allocator export isolation")
struct AllocatorIsolationTests {
    private func leb(_ value: Int) -> [UInt8] {
        var value = value, bytes: [UInt8] = []
        repeat { let next = value >> 7; bytes.append(UInt8(value & 127) | (next == 0 ? 0 : 128)); value = next } while value > 0
        return bytes
    }
    private func image(_ exports: [String: Int], platform: UInt32 = UInt32(PLATFORM_MACCATALYST),
                       type: UInt32 = UInt32(MH_EXECUTE), legacy: Bool = false) -> Data {
        struct Node { var terminal: Int?; var children: [UInt8: Int] = [:] }
        var nodes = [Node()]
        for (name, address) in exports.sorted(by: { $0.key < $1.key }) {
            var at = 0
            for byte in name.utf8 {
                if let child = nodes[at].children[byte] { at = child }
                else { let child = nodes.count; nodes[at].children[byte] = child; nodes.append(Node()); at = child }
            }
            nodes[at].terminal = address
        }
        var offsets: [Int] = [], size = 0
        for node in nodes {
            offsets.append(size)
            size += (node.terminal.map { 2 + leb($0).count } ?? 1) + 1 + node.children.count * 4
        }
        var trie = Data()
        for node in nodes {
            if let address = node.terminal { let payload = [UInt8(0)] + leb(address); trie.append(contentsOf: leb(payload.count) + payload) }
            else { trie.append(0) }
            trie.append(UInt8(node.children.count))
            for (byte, child) in node.children.sorted(by: { $0.key < $1.key }) {
                let offset = offsets[child]
                trie.append(contentsOf: [byte, 0, UInt8(offset & 127) | 128, UInt8(offset >> 7)])
            }
        }
        var binary = Data()
        for word in [MH_MAGIC_64, UInt32(bitPattern: CPU_TYPE_ARM64), 0, type, 2,
                     UInt32(24 + (legacy ? 48 : 16)), 0, 0,
                     UInt32(LC_BUILD_VERSION), 24, platform, 0x1b0000, 0x1b0000, 0] { binary.appendUInt32(word) }
        if legacy {
            for word in [UInt32(LC_DYLD_INFO_ONLY), 48, 0, 0, 0, 0, 0, 0, 0, 0, 0x1000, UInt32(trie.count)] { binary.appendUInt32(word) }
        } else {
            for word in [UInt32(LC_DYLD_EXPORTS_TRIE), 16, 0x1000, UInt32(trie.count)] { binary.appendUInt32(word) }
        }
        binary.append(Data(repeating: 0xa5, count: 0x1000 - binary.count))
        binary.append(trie)
        return binary
    }
    private func exports(_ binary: Data) -> [String: Int] {
        let bytes = Array(binary.dropFirst(0x1000))
        func read(_ cursor: inout Int) -> Int {
            var value = 0, shift = 0
            while true { let byte = bytes[cursor]; cursor += 1; value |= Int(byte & 127) << shift; if byte < 128 { return value }; shift += 7 }
        }
        var work = [(0, "")], result: [String: Int] = [:]
        while let (node, name) = work.popLast() {
            var cursor = node
            let end = read(&cursor) + cursor
            if end > cursor { _ = read(&cursor); result[name] = read(&cursor) }
            cursor = end
            let count = bytes[cursor]; cursor += 1
            for _ in 0..<count {
                let start = cursor
                while bytes[cursor] != 0 { cursor += 1 }
                let suffix = String(decoding: bytes[start..<cursor], as: UTF8.self); cursor += 1
                work.append((read(&cursor), name + suffix))
            }
        }
        return result
    }

    @Test(arguments: [false, true])
    func hidesReplaceableOperatorsButPreservesPlacementAndOtherExports(legacy: Bool) throws {
        let operators = ["__Znwm", "__Znam", "__ZnwmRKSt9nothrow_t", "__ZnamRKSt9nothrow_t", "__ZdlPv", "__ZdaPv",
                         "__ZdlPvm", "__ZdaPvm", "__ZnwmSt11align_val_t", "__ZdlPvSt11align_val_tRKSt9nothrow_t"]
        let kept = ["__ZnwmPv": 0x800, "__ZdlPvS_": 0x801, "__ZN6WidgetnwEm": 0x802, "_GameAPI": 0x803]
        let names = Dictionary(uniqueKeysWithValues: operators.enumerated().map { ($1, 0x400 + $0) }).merging(kept) { $1 }
        var binary = image(names, legacy: legacy), before = binary
        #expect(try MachOBinary.isolateGameAllocatorExports(&binary) == operators.count)
        #expect(exports(binary) == kept)
        #expect(binary.count == before.count)
        #expect(binary.prefix(0x1000) == before.prefix(0x1000))
        before = binary
        #expect(try MachOBinary.isolateGameAllocatorExports(&binary) == 0)
        #expect(binary == before)
    }
    @Test(arguments: [false, true])
    func restoresLegacyExportsWithoutChangingCodeAndKeepsPairs(legacy: Bool) throws {
        let names = ["__Znwm": 0x400, "__ZdlPv": 0x500, "_GameAPI": 0x800]
        var original = image(names, legacy: legacy)
        let commandEnd = 32 + Int(original.uint32(at: 20))
        let symbols = original.count
        var strings = Data([0])
        for (name, address) in names.sorted(by: { $0.key < $1.key }) {
            original.appendUInt32(UInt32(strings.count))
            original.append(contentsOf: [UInt8(N_SECT | N_EXT), 1, 0, 0])
            var value = (UInt64(0x100000000) + UInt64(address)).littleEndian
            Swift.withUnsafeBytes(of: &value) { original.append(contentsOf: $0) }
            strings.append(contentsOf: name.utf8); strings.append(0)
        }
        let stringOffset = original.count
        original.append(strings)
        var segment = Data(count: 72)
        segment.setUInt32(UInt32(LC_SEGMENT_64), at: 0); segment.setUInt32(72, at: 4)
        segment.replaceSubrange(8..<14, with: Data("__TEXT".utf8))
        segment.setUInt32(1, at: 28) // vmaddr 0x100000000
        var symtab = Data()
        for word in [UInt32(LC_SYMTAB), 24, UInt32(symbols), UInt32(names.count), UInt32(stringOffset), UInt32(strings.count)] {
            symtab.appendUInt32(word)
        }
        original.replaceSubrange(commandEnd..<(commandEnd + 72), with: segment)
        original.replaceSubrange((commandEnd + 72)..<(commandEnd + 96), with: symtab)
        original.setUInt32(4, at: 16)
        original.setUInt32(UInt32(commandEnd - 32 + 96), at: 20)
        var binary = original
        #expect(try MachOBinary.restoreGameAllocatorExports(&binary) == 0)
        #expect(try MachOBinary.isolateGameAllocatorExports(&binary) == 2)
        #expect(try MachOBinary.restoreGameAllocatorExports(&binary) == 2)
        #expect(binary == original)
        #expect(exports(binary) == names)
        #expect(try MachOBinary.restoreGameAllocatorExports(&binary) == 0)
    }

    @Test func leavesNativeAppsAndFrameworksUntouched() throws {
        for (platform, type) in [(UInt32(PLATFORM_MACOS), UInt32(MH_EXECUTE)), (UInt32(PLATFORM_MACCATALYST), UInt32(MH_DYLIB))] {
            var binary = image(["__Znwm": 0x400], platform: platform, type: type), before = binary
            #expect(try MachOBinary.isolateGameAllocatorExports(&binary) == 0)
            #expect(binary == before)
        }
    }
    @Test func malformedTriesDoNotPartiallyEditTheBinary() throws {
        var binary = image(["__Znwm": 0x400])
        binary.setUInt32(UInt32.max, at: 64)
        let before = binary
        #expect(throws: MachOBinary.Failure.self) { try MachOBinary.isolateGameAllocatorExports(&binary) }
        #expect(binary == before)
        binary = image(["__Znwm": 0x400])
        // A root edge points back to the root.
        binary[0x1000 + 4] = 0x80; binary[0x1000 + 5] = 0
        let cyclic = binary
        #expect(throws: MachOBinary.Failure.self) { try MachOBinary.isolateGameAllocatorExports(&binary) }
        #expect(binary == cyclic)
    }

    @Test func nativeLoaderDoesNotUseTheGameHeapBeforeMain() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mulg-allocator-" + UUID().uuidString)
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: folder) }
        let framework = folder.appendingPathComponent("Framework.cpp"), main = folder.appendingPathComponent("Game.cpp")
        try Data("""
            #include <new>
            __attribute__((constructor)) static void prepare() {
                void *p = ::operator new(32); ::operator delete(p);
            }
            extern "C" int framework_ready() { return 1; }
            """.utf8).write(to: framework)
        try Data("""
            #include <cstdlib>
            #include <new>
            static bool ready; static int game_allocations;
            void *operator new(std::size_t size) { if (!ready) std::_Exit(71); ++game_allocations; return std::malloc(size); }
            void operator delete(void *p) noexcept { std::free(p); }
            extern "C" int framework_ready();
            int main() { ready = true; void *p = ::operator new(16); ::operator delete(p); return game_allocations == 1 && framework_ready() ? 0 : 72; }
            """.utf8).write(to: main)
        let dylib = folder.appendingPathComponent("Framework.dylib"), game = folder.appendingPathComponent("Game")
        try #require(try run("/usr/bin/xcrun", ["clang++", "-dynamiclib", framework.path, "-install_name", "@executable_path/Framework.dylib", "-o", dylib.path]) == 0)
        try #require(try run("/usr/bin/xcrun", ["clang++", main.path, dylib.path, "-Wl,-export_dynamic", "-o", game.path]) == 0)
        #expect(try run(game.path, []) == 71)
        var binary = try Data(contentsOf: game)
        let build = try #require(try MachOBinary.loadCommands(in: binary).first { $0.command == UInt32(LC_BUILD_VERSION) })
        binary.setUInt32(UInt32(PLATFORM_MACCATALYST), at: build.offset + 8)
        #expect(try MachOBinary.isolateGameAllocatorExports(&binary) == 2)
        binary.setUInt32(UInt32(PLATFORM_MACOS), at: build.offset + 8)
        try binary.write(to: game)
        try #require(try run("/usr/bin/codesign", ["--force", "--sign", "-", game.path]) == 0)
        #expect(try run(game.path, []) == 0)
    }
    private func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        try process.run(); _ = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return process.terminationStatus
    }
}
#endif
