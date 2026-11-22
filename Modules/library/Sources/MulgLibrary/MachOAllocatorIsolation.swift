#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import MachO

extension MachOBinary {
    /// Legacy transform retained for migration regression fixtures only. Production
    /// preserves allocator exports so system libc++ and game code share ownership.
    @discardableResult
    static func isolateGameAllocatorExports(_ binary: inout Data) throws -> Int {
        try editGameAllocatorExports(&binary, restoring: false)
    }

    /// Repair exports removed by older Mulg versions. Keeping direct game allocations
    /// but hiding their operators splits ownership when system libc++ destroys them.
    /// Only reconstruct existing trie nodes from defined external symbol metadata.
    @discardableResult
    public static func restoreGameAllocatorExports(_ binary: inout Data) throws -> Int {
        try editGameAllocatorExports(&binary, restoring: true)
    }

    private static func editGameAllocatorExports(_ binary: inout Data, restoring: Bool) throws -> Int {
        let commands = try loadCommands(in: binary)
        guard binary.uint32(at: 12) == UInt32(MH_EXECUTE),
              let platform = try buildInfo(of: binary)?.platform,
              [UInt32(PLATFORM_IOS), UInt32(PLATFORM_MACCATALYST)].contains(platform) else { return 0 }
        let definitions = restoring ? try allocatorDefinitions(in: binary, commands: commands) : [:]
        let headerEnd = 32 + Int(binary.uint32(at: 20))
        var ranges: Set<Range<Int>> = []
        for command in commands {
            let fields: (Int, Int)?
            switch command.command {
            case UInt32(LC_DYLD_EXPORTS_TRIE):
                guard command.size >= 16 else { throw Failure.corrupted("allocator export command") }
                fields = (8, 12)
            case UInt32(LC_DYLD_INFO), UInt32(LC_DYLD_INFO_ONLY):
                guard command.size >= 48 else { throw Failure.corrupted("allocator dyld info command") }
                fields = (40, 44)
            default: fields = nil
            }
            guard let fields else { continue }
            let start = Int(binary.uint32(at: command.offset + fields.0))
            let size = Int(binary.uint32(at: command.offset + fields.1))
            guard size != 0 else { continue }
            guard start >= headerEnd, start <= binary.count, size <= binary.count - start else {
                throw Failure.corrupted("allocator export range")
            }
            let range = start..<(start + size)
            guard !ranges.contains(where: { $0 != range && $0.overlaps(range) }) else {
                throw Failure.corrupted("overlapping allocator exports")
            }
            ranges.insert(range)
        }
        // Validate every trie before publishing any edit, including unrelated branches.
        var changes: [(Range<Int>, Data)] = []
        for range in ranges {
            let bytes = Array(binary[range])
            func leb(_ cursor: inout Int) throws -> UInt64 {
                var result: UInt64 = 0
                for index in 0..<10 {
                    guard cursor < bytes.count else { throw Failure.corrupted("truncated allocator export LEB") }
                    let byte = bytes[cursor]; cursor += 1
                    guard index != 9 || byte <= 1 else { throw Failure.corrupted("allocator export LEB overflow") }
                    result |= UInt64(byte & 127) << (index * 7)
                    if byte < 128 { return result }
                }
                throw Failure.corrupted("allocator export LEB overflow")
            }
            var repairs: [(node: Int, end: Int, bytes: Data)] = []
            var pending: [(Int, String, Set<Int>)] = [(0, "", [])]
            var visited: Set<Int> = [], nodes: [Range<Int>] = []
            while let (node, name, ancestors) = pending.popLast() {
                guard node >= 0, node < bytes.count, !ancestors.contains(node) else {
                    throw Failure.corrupted("cyclic allocator export node")
                }
                // A shared node can also name an unrelated alias. Leave such tries intact.
                guard visited.insert(node).inserted else { return 0 }
                var path = ancestors; path.insert(node)
                var cursor = node
                let size = try leb(&cursor)
                guard size <= UInt64(bytes.count - cursor) else { throw Failure.corrupted("allocator export terminal") }
                let terminal = cursor, children = cursor + Int(size)
                guard children < bytes.count else { throw Failure.corrupted("allocator export children") }
                cursor = children + 1
                for _ in 0..<Int(bytes[children]) {
                    let start = cursor
                    while cursor < bytes.count && bytes[cursor] != 0 { cursor += 1 }
                    guard cursor < bytes.count, cursor > start,
                          let suffix = String(bytes: bytes[start..<cursor], encoding: .utf8),
                          name.utf8.count + suffix.utf8.count <= 4096 else {
                        throw Failure.corrupted("allocator export edge")
                    }
                    cursor += 1
                    let child = try leb(&cursor)
                    guard child < bytes.count else { throw Failure.corrupted("allocator export child offset") }
                    pending.append((Int(child), name + suffix, path))
                }
                let nodeRange = node..<cursor
                nodes.append(nodeRange)
                if restoring, size == 0, gameAllocatorSymbols.contains(name),
                   bytes[children] == 0, definitions[name] == nil {
                    throw Failure.corrupted("missing original allocator metadata; reimport the original IPA")
                }
                if restoring, size == 0, let definition = definitions[name] {
                    let payload = allocatorLEB(definition.flags) + allocatorLEB(definition.address)
                    var replacement = Data(allocatorLEB(UInt64(payload.count)) + payload)
                    replacement.append(contentsOf: bytes[children..<cursor])
                    repairs.append((node, cursor, replacement))
                }
                if !restoring, size > 0, gameAllocatorSymbols.contains(name) {
                    // Do not hide re-exports, resolvers, absolute addresses or TLV data.
                    var flagsCursor = terminal
                    let flags = try leb(&flagsCursor)
                    guard flagsCursor <= children, flags & ~UInt64(EXPORT_SYMBOL_FLAGS_WEAK_DEFINITION) == 0 else { continue }
                    let address = try leb(&flagsCursor)
                    guard flagsCursor == children, address < binary.count else {
                        throw Failure.corrupted("allocator export address")
                    }
                    // Empty terminal, then the original children and their absolute trie offsets.
                    // Moving only this node's child table leaves all other nodes at their old offsets.
                    var replacement = Data([0])
                    replacement.append(contentsOf: bytes[children..<cursor])
                    replacement.append(Data(count: nodeRange.count - replacement.count))
                    changes.append(((range.lowerBound + node)..<(range.lowerBound + cursor), replacement))
                }
            }
            let ordered = nodes.sorted { $0.lowerBound < $1.lowerBound }
            for index in ordered.indices.dropFirst() where ordered[index - 1].overlaps(ordered[index]) {
                throw Failure.corrupted("overlapping allocator export nodes")
            }
            for repair in repairs {
                let end = repair.node + repair.bytes.count
                let limit = ordered.first(where: { $0.lowerBound > repair.node })?.lowerBound ?? bytes.count
                guard end <= limit, end >= repair.end,
                      bytes[repair.end..<end].allSatisfy({ $0 == 0 }) else {
                    throw Failure.corrupted("allocator export restoration requires original binary")
                }
                changes.append(((range.lowerBound + repair.node)..<(range.lowerBound + end), repair.bytes))
            }
        }
        for (range, replacement) in changes { binary.replaceSubrange(range, with: replacement) }
        return changes.count
    }

    private static func allocatorLEB(_ value: UInt64) -> [UInt8] {
        var value = value, bytes: [UInt8] = []
        repeat {
            let byte = UInt8(value & 127); value >>= 7
            bytes.append(byte | (value == 0 ? 0 : 128))
        } while value != 0
        return bytes
    }

    private static func allocatorDefinitions(in binary: Data, commands: [LoadCommand]) throws
        -> [String: (flags: UInt64, address: UInt64)] {
        guard let text = commands.first(where: {
            $0.command == UInt32(LC_SEGMENT_64) && $0.size >= 72
                && String(data: binary[($0.offset + 8)..<($0.offset + 14)], encoding: .utf8) == "__TEXT"
        }), let symbols = commands.first(where: { $0.command == UInt32(LC_SYMTAB) }) else { return [:] }
        guard symbols.size >= 24 else { throw Failure.corrupted("allocator symbol command") }
        let base = binary.uint64(at: text.offset + 24)
        let table = Int(binary.uint32(at: symbols.offset + 8)), count = Int(binary.uint32(at: symbols.offset + 12))
        let strings = Int(binary.uint32(at: symbols.offset + 16)), length = Int(binary.uint32(at: symbols.offset + 20))
        guard table <= binary.count, count <= (binary.count - table) / 16,
              strings <= binary.count, length <= binary.count - strings else {
            throw Failure.corrupted("allocator symbol range")
        }
        var result: [String: (flags: UInt64, address: UInt64)] = [:]
        for index in 0..<count {
            let at = table + index * 16, type = binary[at + 4]
            guard type & UInt8(N_STAB) == 0, type & UInt8(N_TYPE) == UInt8(N_SECT),
                  type & UInt8(N_EXT) != 0, type & UInt8(N_PEXT) == 0 else { continue }
            let offset = Int(binary.uint32(at: at))
            guard offset < length, let end = binary[(strings + offset)..<(strings + length)].firstIndex(of: 0),
                  let name = String(data: binary[(strings + offset)..<end], encoding: .utf8) else {
                throw Failure.corrupted("allocator symbol name")
            }
            guard gameAllocatorSymbols.contains(name) else { continue }
            let address = binary.uint64(at: at + 8)
            guard address >= base, address - base < binary.count else { throw Failure.corrupted("allocator symbol address") }
            let flags: UInt64 = binary[at + 6] & UInt8(N_WEAK_DEF) != 0 ? UInt64(EXPORT_SYMBOL_FLAGS_WEAK_DEFINITION) : 0
            guard result[name] == nil else { throw Failure.corrupted("duplicate allocator symbol") }
            result[name] = (flags, address - base)
        }
        return result
    }

    private static let gameAllocatorSymbols: Set<String> = {
        var names: Set<String> = []
        for operation in ["__Znwm", "__Znam"] {
            for suffix in ["", "RKSt9nothrow_t", "St11align_val_t", "St11align_val_tRKSt9nothrow_t"] {
                names.insert(operation + suffix)
            }
        }
        for operation in ["__ZdlPv", "__ZdaPv"] {
            for suffix in ["", "m", "RKSt9nothrow_t", "St11align_val_t", "mSt11align_val_t",
                           "St11align_val_tRKSt9nothrow_t"] { names.insert(operation + suffix) }
        }
        return names
    }()
}
#endif
