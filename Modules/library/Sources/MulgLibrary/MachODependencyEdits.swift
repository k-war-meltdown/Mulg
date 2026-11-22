#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import MachO

extension MachOBinary {
    /// Ordinal fields move with the library list. Never relocate linkedit payloads: a smaller
    /// ordinal fits its old LEB width (zero padding is valid), while removed providers fail closed.
    static func remapLibraryOrdinals(_ binary: inout Data, removing: Set<Int>, count: Int) throws {
        guard !removing.isEmpty else { return }
        guard count <= 253 else { throw Failure.corrupted("unsupported library ordinal count") }
        var next = 0
        let mapping = (0...count).map { ordinal -> Int? in
            if ordinal == 0 { return 0 }
            if removing.contains(ordinal) { return nil }
            next += 1; return next
        }
        func remap(_ ordinal: UInt64) throws -> UInt64 {
            guard ordinal > 0 else { return ordinal }
            guard ordinal <= UInt64(count), let value = mapping[Int(ordinal)] else {
                throw Failure.corrupted("removed or invalid library provider \(ordinal)")
            }
            return UInt64(value)
        }
        func payload(_ offset: UInt32, _ size: UInt64) throws -> Range<Int> {
            let start = Int(offset)
            guard (size == 0 || start >= 32 + Int(binary.uint32(at: 20))),
                  start <= binary.count, size <= UInt64(binary.count - start) else {
                throw Failure.corrupted("ordinal payload outside file")
            }
            return start..<(start + Int(size))
        }
        var edited: Set<Range<Int>> = []
        func edit(_ range: Range<Int>, _ body: (inout [UInt8]) throws -> Void) throws {
            guard !range.isEmpty, !edited.contains(range) else { return }
            guard !edited.contains(where: { $0.overlaps(range) }) else { throw Failure.corrupted("overlapping ordinal payloads") }
            edited.insert(range)
            var bytes = Array(binary[(binary.startIndex + range.lowerBound)..<(binary.startIndex + range.upperBound)])
            try body(&bytes)
            binary.replaceSubrange((binary.startIndex + range.lowerBound)..<(binary.startIndex + range.upperBound), with: bytes)
        }
        func leb(_ bytes: [UInt8], _ cursor: inout Int, end: Int) throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<10 {
                guard cursor < end else { throw Failure.corrupted("truncated ordinal LEB") }
                let byte = bytes[cursor]; cursor += 1
                guard index != 9 || byte <= 1 else { throw Failure.corrupted("ordinal LEB overflow") }
                value |= UInt64(byte & 127) << (index * 7)
                if byte & 128 == 0 { return value }
            }
            throw Failure.corrupted("ordinal LEB overflow")
        }
        func skipLEB(_ bytes: [UInt8], _ cursor: inout Int) throws {
            for _ in 0..<10 {
                guard cursor < bytes.count else { throw Failure.corrupted("truncated bind operand") }
                let byte = bytes[cursor]; cursor += 1
                if byte & 128 == 0 { return }
            }
            throw Failure.corrupted("bind operand overflow")
        }
        func string(_ bytes: [UInt8], _ cursor: inout Int, end: Int) throws {
            while cursor < end {
                let byte = bytes[cursor]; cursor += 1
                if byte == 0 { return }
            }
            throw Failure.corrupted("unterminated ordinal string")
        }
        func ordinalLEB(_ bytes: inout [UInt8], _ cursor: inout Int, end: Int) throws {
            let start = cursor
            var value = try remap(leb(bytes, &cursor, end: end))
            for index in start..<cursor {
                bytes[index] = UInt8(value & 127) | (index + 1 < cursor ? 128 : 0)
                value >>= 7
            }
        }
        func binds(_ range: Range<Int>) throws {
            try edit(range) { bytes in
                var cursor = 0
                while cursor < bytes.count {
                    let index = cursor, opcode = bytes[cursor]; cursor += 1
                    switch opcode & 0xf0 {
                    case 0x00, 0x30, 0x50, 0x90, 0xb0: break
                    case 0x10: bytes[index] = 0x10 | UInt8(try remap(UInt64(opcode & 15)))
                    case 0x20: try ordinalLEB(&bytes, &cursor, end: bytes.count)
                    case 0x40: try string(bytes, &cursor, end: bytes.count)
                    case 0x60, 0x70, 0x80, 0xa0: try skipLEB(bytes, &cursor)
                    case 0xc0: try skipLEB(bytes, &cursor); try skipLEB(bytes, &cursor)
                    case 0xd0:
                        if opcode & 15 == 0 { try skipLEB(bytes, &cursor) }
                        else if opcode & 15 != 1 { throw Failure.corrupted("unknown threaded bind") }
                    default: throw Failure.corrupted("unknown bind opcode")
                    }
                }
            }
        }
        func exports(_ range: Range<Int>) throws {
            guard !range.isEmpty else { return }
            try edit(range) { bytes in
                var pending = [0], visited: Set<Int> = []
                while let node = pending.popLast() {
                    guard visited.insert(node).inserted else { continue }
                    var cursor = node
                    let size = try leb(bytes, &cursor, end: bytes.count)
                    guard size <= UInt64(bytes.count - cursor) else { throw Failure.corrupted("export terminal") }
                    let end = cursor + Int(size)
                    if size > 0 {
                        let flags = try leb(bytes, &cursor, end: end)
                        if flags & 8 != 0 {
                            try ordinalLEB(&bytes, &cursor, end: end)
                            try string(bytes, &cursor, end: end)
                        }
                    }
                    cursor = end
                    guard cursor < bytes.count else { throw Failure.corrupted("export children") }
                    let children = bytes[cursor]; cursor += 1
                    for _ in 0..<children {
                        try string(bytes, &cursor, end: bytes.count)
                        let child = try leb(bytes, &cursor, end: bytes.count)
                        guard child < bytes.count else { throw Failure.corrupted("export node offset") }
                        pending.append(Int(child))
                    }
                }
            }
        }
        for command in try loadCommands(in: binary) {
            let base = command.offset
            switch command.command {
            case UInt32(LC_SYMTAB):
                guard command.size >= 24 else { throw Failure.corrupted("symbol command") }
                let range = try payload(binary.uint32(at: base + 8), UInt64(binary.uint32(at: base + 12)) * 16)
                if binary.uint32(at: 24) & UInt32(MH_TWOLEVEL) != 0 {
                    try edit(range) { bytes in
                        for symbol in stride(from: 0, to: bytes.count, by: 16) {
                            let type = bytes[symbol + 4]
                            if type & UInt8(N_STAB) == 0 && [UInt8(N_UNDF), UInt8(N_PBUD)].contains(type & UInt8(N_TYPE)) {
                                let ordinal = bytes[symbol + 7]
                                if ordinal < 254 { bytes[symbol + 7] = UInt8(try remap(UInt64(ordinal))) }
                            }
                        }
                    }
                }
            case UInt32(LC_DYLD_INFO), UInt32(LC_DYLD_INFO_ONLY):
                guard command.size >= 48 else { throw Failure.corrupted("dyld info command") }
                for field in [16, 24, 32] {
                    try binds(payload(binary.uint32(at: base + field), UInt64(binary.uint32(at: base + field + 4))))
                }
                try exports(payload(binary.uint32(at: base + 40), UInt64(binary.uint32(at: base + 44))))
            case UInt32(LC_DYLD_EXPORTS_TRIE):
                guard command.size >= 16 else { throw Failure.corrupted("exports command") }
                try exports(payload(binary.uint32(at: base + 8), UInt64(binary.uint32(at: base + 12))))
            case UInt32(LC_DYLD_CHAINED_FIXUPS):
                guard command.size >= 16 else { throw Failure.corrupted("chained command") }
                let range = try payload(binary.uint32(at: base + 8), UInt64(binary.uint32(at: base + 12)))
                guard range.count >= 28, binary.uint32(at: range.lowerBound) == 0 else { throw Failure.corrupted("chained header") }
                let offset = Int(binary.uint32(at: range.lowerBound + 8))
                let count = UInt64(binary.uint32(at: range.lowerBound + 16))
                let format = binary.uint32(at: range.lowerBound + 20)
                if count == 0 { continue }
                guard [UInt32(1), 2, 3].contains(format) else { throw Failure.corrupted("chained imports format") }
                let width = format == 3 ? 16 : (format == 2 ? 8 : 4)
                guard offset >= 28, offset <= range.count, count <= UInt64((range.count - offset) / width) else {
                    throw Failure.corrupted("chained imports range")
                }
                try edit(range) { bytes in
                    for item in 0..<Int(count) {
                        let at = offset + item * width
                        if format == 3 {
                            let ordinal = UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
                            if ordinal > 0 && ordinal <= 0xfff0 {
                                let new = try remap(UInt64(ordinal))
                                bytes[at] = UInt8(new & 255); bytes[at + 1] = UInt8(new >> 8)
                            }
                        } else if bytes[at] > 0 && bytes[at] <= 0xf0 {
                            bytes[at] = UInt8(try remap(UInt64(bytes[at])))
                        }
                    }
                }
            case UInt32(LC_TWOLEVEL_HINTS):
                // These obsolete hints have another index namespace; preserve them by refusing
                // removal rather than guessing how to rewrite their sub-image indexes.
                throw Failure.corrupted("library removal with legacy two-level hints")
            default: break
            }
        }
    }
}
#endif
