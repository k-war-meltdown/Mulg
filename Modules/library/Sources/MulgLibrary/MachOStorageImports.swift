#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import MachO

extension MachOBinary {
    /// True when the image walks the process's loaded-image list (image count plus image
    /// names or headers). Integrity-checking SDKs do this to verify where their system calls
    /// resolve, and treat a foreign provider as tampering. Such images keep native imports.
    static func inspectsLoadedImages(_ binary: Data) throws -> Bool {
        guard let symtab = try loadCommands(in: binary).first(where: { $0.command == UInt32(LC_SYMTAB) }) else {
            return false
        }
        guard symtab.size >= 24 else { throw Failure.corrupted("image inspection symbol command") }
        let table = Int(binary.uint32(at: symtab.offset + 8)), count = Int(binary.uint32(at: symtab.offset + 12))
        let strings = Int(binary.uint32(at: symtab.offset + 16)), length = Int(binary.uint32(at: symtab.offset + 20))
        guard table <= binary.count, count <= (binary.count - table) / 16,
              strings <= binary.count, length <= binary.count - strings else {
            throw Failure.corrupted("image inspection symbol table")
        }
        var imported: Set<String> = []
        for symbol in stride(from: table, to: table + count * 16, by: 16) {
            let type = binary[symbol + 4]
            guard type & UInt8(N_STAB) == 0, type & UInt8(N_TYPE) == UInt8(N_UNDF) else { continue }
            let start = strings + Int(binary.uint32(at: symbol))
            guard start < strings + length,
                  let end = binary[start..<(strings + length)].firstIndex(of: 0) else { continue }
            let name = String(decoding: binary[start..<end], as: UTF8.self)
            if name.hasPrefix("__dyld_") { imported.insert(name) }
        }
        return imported.contains("__dyld_image_count")
            && (imported.contains("__dyld_get_image_name") || imported.contains("__dyld_get_image_header"))
    }

    /// Storage adapters are ordinary, explicitly linked C exports. Unlike a process-wide
    /// interpose, their declared provider agrees with the address dyld puts in each import.
    /// Only the installer's staged game images are edited; native frameworks are unchanged.
    @discardableResult
    static func routeStorageImports(_ binary: inout Data, runtimePath: String?) throws -> Bool {
        let libraries = try loadedLibraries(in: binary)
        let runtime = try runtimePath.map { path -> Int in
            guard let index = libraries.firstIndex(of: path), index < 253 else {
                throw Failure.corrupted("missing storage adapter dependency")
            }
            return index + 1
        }
        let fileSymbols: Set<String> = ["_open", "_stat", "_access", "_rename", "_unlink", "_mkdir", "_rmdir", "_lstat", "_opendir", "_fopen", "_statfs", "_statvfs"]
        // Installed games bind credential calls to MulgRuntime's virtual Keychain exports.
        // Security is used here only as the original provider when removing MulgRuntime.
        let credentialSymbols: Set<String> = ["_SecItemCopyMatching", "_SecItemAdd", "_SecItemUpdate", "_SecItemDelete",
                                              "_SecKeyCreateRandomKey", "_SecKeyGeneratePair"]
        let symbols: Set<String> = fileSymbols.union(credentialSymbols).union(["_getenv", "_NSHomeDirectory", "_NSTemporaryDirectory", "_NSSearchPathForDirectoriesInDomains", "_sysctl", "_sysctlbyname", "_gethostname"])
        func native(_ name: String, _ path: String) -> Bool {
            if credentialSymbols.contains(name) {
                return path == "/System/Library/Frameworks/Security.framework/Security"
                    || path.hasPrefix("/System/iOSSupport/System/Library/Frameworks/Security.framework/")
            }
            if name == "_getenv" || ["_sysctl", "_sysctlbyname", "_gethostname"].contains(name) || fileSymbols.contains(name) {
                return ["/usr/lib/libSystem.B.dylib", "/usr/lib/libSystem.dylib", "/usr/lib/system/libsystem_c.dylib", "/usr/lib/system/libsystem_kernel.dylib"].contains(path)
            }
            return path.hasPrefix("/System/") && path.contains("/Foundation.framework/")
        }
        func isRuntime(_ path: String) -> Bool {
            RuntimeInstaller.isRuntimeLibrary(path) || path.hasSuffix("/GameRuntime.framework/MulgKit")
        }
        func provider(_ ordinal: Int, name: String) throws -> Int {
            guard symbols.contains(name), ordinal > 0, ordinal <= libraries.count else { return ordinal }
            let old = libraries[ordinal - 1]
            guard native(name, old) || isRuntime(old) || old == runtimePath else { return ordinal }
            if let runtime { return runtime }
            if native(name, old) { return ordinal }
            guard let index = libraries.firstIndex(where: { native(name, $0) }) else {
                throw Failure.corrupted("missing native storage provider for \(name)")
            }
            return index + 1
        }
        let commands = try loadCommands(in: binary)
        let headerEnd = 32 + Int(binary.uint32(at: 20))
        let linkedit = commands.first {
            $0.command == UInt32(LC_SEGMENT_64) && $0.size >= 72
                && String(data: binary[($0.offset + 8)..<($0.offset + 18)], encoding: .utf8) == "__LINKEDIT"
        }
        var updated = binary
        func range(_ offset: UInt32, _ size: UInt64) throws -> Range<Int> {
            let start = Int(offset)
            guard start <= binary.count, size <= UInt64(binary.count - start), size == 0 || start >= headerEnd else {
                throw Failure.corrupted("storage import payload")
            }
            if size > 0 {
                guard let linkedit else { throw Failure.corrupted("missing storage import LINKEDIT") }
                let base = binary.uint64(at: linkedit.offset + 40), length = binary.uint64(at: linkedit.offset + 48)
                guard UInt64(start) >= base, UInt64(start) - base <= length,
                      size <= length - (UInt64(start) - base) else {
                    throw Failure.corrupted("storage imports outside LINKEDIT")
                }
            }
            return start..<(start + Int(size))
        }
        func name(_ bytes: Data, at start: Int, end: Int) throws -> String {
            guard start >= 0, start < end, end <= bytes.count,
                  let zero = bytes[start..<end].firstIndex(of: 0),
                  let value = String(data: bytes[start..<zero], encoding: .utf8) else {
                throw Failure.corrupted("storage import name")
            }
            return value
        }
        var streams: [(field: Int, bytes: Data)] = []
        for command in commands {
            let base = command.offset
            switch command.command {
            case UInt32(LC_SYMTAB):
                guard command.size >= 24 else { throw Failure.corrupted("storage symbol command") }
                let table = try range(binary.uint32(at: base + 8), UInt64(binary.uint32(at: base + 12)) * 16)
                let strings = try range(binary.uint32(at: base + 16), UInt64(binary.uint32(at: base + 20)))
                for symbol in stride(from: table.lowerBound, to: table.upperBound, by: 16) {
                    let type = binary[symbol + 4]
                    guard type & UInt8(N_STAB) == 0, [UInt8(N_UNDF), UInt8(N_PBUD)].contains(type & UInt8(N_TYPE)),
                          binary.uint32(at: 24) & UInt32(MH_TWOLEVEL) != 0 else { continue }
                    let string = Int(binary.uint32(at: symbol))
                    guard string < strings.count else { throw Failure.corrupted("storage symbol string") }
                    let value = try name(binary, at: strings.lowerBound + string, end: strings.upperBound)
                    let old = Int(binary[symbol + 7])
                    if old < 254 { updated[symbol + 7] = UInt8(try provider(old, name: value)) }
                }
            case UInt32(LC_DYLD_CHAINED_FIXUPS):
                guard command.size >= 16 else { throw Failure.corrupted("storage chained command") }
                let payload = try range(binary.uint32(at: base + 8), UInt64(binary.uint32(at: base + 12)))
                guard payload.count >= 28, binary.uint32(at: payload.lowerBound) == 0 else {
                    throw Failure.corrupted("storage chained header")
                }
                let root = payload.lowerBound, count = Int(binary.uint32(at: root + 16))
                if count == 0 { continue }
                let format = binary.uint32(at: root + 20)
                guard [UInt32(1), 2, 3].contains(format), binary.uint32(at: root + 24) == 0 else {
                    throw Failure.corrupted("unsupported storage chained import format")
                }
                let imports = Int(binary.uint32(at: root + 8)), strings = Int(binary.uint32(at: root + 12))
                let width = format == 3 ? 16 : (format == 2 ? 8 : 4)
                guard imports >= 28, imports <= payload.count, count <= (payload.count - imports) / width,
                      strings >= imports + count * width, strings < payload.count else {
                    throw Failure.corrupted("storage chained import range")
                }
                for item in 0..<count {
                    let at = root + imports + item * width
                    let raw = format == 3 ? binary.uint64(at: at) : UInt64(binary.uint32(at: at))
                    let ordinal = format == 3 ? Int(raw & 0xffff) : Int(raw & 0xff)
                    if ordinal == 0 || ordinal >= (format == 3 ? 0xfff0 : 0xf0) { continue }
                    let offset = Int(format == 3 ? raw >> 32 : raw >> 9)
                    guard offset < payload.count - strings else { throw Failure.corrupted("storage chained symbol offset") }
                    let value = try name(binary, at: root + strings + offset, end: payload.upperBound)
                    let new = try provider(ordinal, name: value)
                    guard format == 3 || new < 0xf0 else { throw Failure.corrupted("storage chained provider overflow") }
                    updated[at] = UInt8(new & 255)
                    if format == 3 { updated[at + 1] = UInt8(new >> 8) }
                }
            case UInt32(LC_DYLD_INFO), UInt32(LC_DYLD_INFO_ONLY):
                guard command.size >= 48 else { throw Failure.corrupted("storage bind command") }
                // Weak lookup has no explicit library provider. Normal and lazy bindings do.
                for field in [16, 32] {
                    let payload = try range(binary.uint32(at: base + field), UInt64(binary.uint32(at: base + field + 4)))
                    let original = binary.subdata(in: payload)
                    let routed = field == 32
                        ? try storageLazyBindStream(original, commands: commands, binary: &updated, provider: provider)
                        : try storageBindStream(original, provider: provider)
                    if routed != original { streams.append((base + field, routed)) }
                }
            default: break
            }
        }
        if !streams.isEmpty { try appendStorageBindStreams(streams, commands: commands, binary: &updated) }
        guard updated != binary else { return false }
        binary = updated
        return true
    }

    /// Lazy helpers contain offsets into individual DONE-terminated records, not file
    /// offsets. Re-encoding a provider can move every subsequent record. Recover each
    /// helper from its bound pointer slot so refresh also repairs older converted images
    /// whose helper literals no longer match their already-rewritten stream.
    private static func storageLazyBindStream(_ bytes: Data, commands: [LoadCommand], binary: inout Data,
                                              provider: (Int, String) throws -> Int) throws -> Data {
        struct Segment { let offset: Int; let size: Int }
        struct Helpers { let address: UInt64; let offset: Int; let size: Int }
        var segments: [Segment] = [], helpers: [Helpers] = []
        for command in commands where command.command == UInt32(LC_SEGMENT_64) {
            let at = command.offset
            guard command.size >= 72 else { throw Failure.corrupted("lazy storage segment") }
            let address = binary.uint64(at: at + 24), offset = binary.uint64(at: at + 40)
            let size = binary.uint64(at: at + 48), count = Int(binary.uint32(at: at + 64))
            guard offset <= UInt64(binary.count), size <= UInt64(binary.count) - offset,
                  count <= (command.size - 72) / 80 else { throw Failure.corrupted("lazy storage segment range") }
            segments.append(Segment(offset: Int(offset), size: Int(size)))
            for index in 0..<count {
                let section = at + 72 + index * 80
                let name = String(decoding: binary[section..<(section + 16)].prefix { $0 != 0 }, as: UTF8.self)
                guard name == "__stub_helper" else { continue }
                let start = binary.uint64(at: section + 32), length = binary.uint64(at: section + 40)
                let file = UInt64(binary.uint32(at: section + 48))
                guard binary.uint32(at: at + 60) & 4 != 0, start >= address,
                      start - address <= size, length <= size - (start - address),
                      file == offset + (start - address) else { throw Failure.corrupted("lazy storage helper range") }
                helpers.append(Helpers(address: start, offset: Int(file), size: Int(length)))
            }
        }
        var cursor = 0, record = 0, segment: Int?, address: UInt64 = 0, output = Data()
        var targets: [(Int, UInt64)] = [], patched: [Int: UInt32] = [:]
        func leb() throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<10 {
                guard cursor < bytes.count else { throw Failure.corrupted("lazy storage operand") }
                let byte = bytes[cursor]; cursor += 1
                guard index != 9 || byte <= 1 else { throw Failure.corrupted("lazy storage operand overflow") }
                value |= UInt64(byte & 127) << (index * 7)
                if byte < 128 { return value }
            }
            throw Failure.corrupted("lazy storage operand overflow")
        }
        func advance(_ amount: UInt64) throws {
            guard amount <= UInt64.max - address else { throw Failure.corrupted("lazy storage address overflow") }
            address += amount
        }
        func bind() throws {
            guard let segment, segment < segments.count, targets.count < binary.count / 8 else {
                throw Failure.corrupted("lazy storage bind target")
            }
            targets.append((segment, address))
            try advance(8)
        }
        while cursor < bytes.count {
            let opcode = bytes[cursor]; cursor += 1
            switch opcode & 0xf0 {
            case 0x00:
                guard output.count <= Int(UInt32.max) else { throw Failure.corrupted("lazy storage record offset") }
                let entry = UInt32(output.count)
                for (index, displacement) in targets {
                    let target = segments[index]
                    guard displacement <= UInt64(target.size), UInt64(target.size) - displacement >= 8 else {
                        throw Failure.corrupted("lazy storage pointer range")
                    }
                    let pointer = binary.uint64(at: target.offset + Int(displacement))
                    guard let helper = helpers.first(where: {
                        pointer >= $0.address && pointer - $0.address < UInt64($0.size)
                    }) else { continue } // An already-bound/zero pointer has no lazy helper.
                    guard binary.uint32(at: 4) == UInt32(bitPattern: CPU_TYPE_ARM64) else {
                        throw Failure.corrupted("unsupported lazy storage helper architecture")
                    }
                    let within = Int(pointer - helper.address)
                    guard within <= helper.size - 12 else { throw Failure.corrupted("truncated lazy storage helper") }
                    var instruction = helper.offset + within
                    // ARM64 linkers may prefix a helper with BTI or NOP.
                    if [UInt32(0xd503245f), 0xd503249f, 0xd50324df, 0xd503201f].contains(binary.uint32(at: instruction)) {
                        instruction += 4
                    }
                    guard instruction <= helper.offset + helper.size - 12,
                          binary.uint32(at: instruction) == 0x18000050,
                          binary.uint32(at: instruction + 4) & 0xfc000000 == 0x14000000 else {
                        throw Failure.corrupted("unsupported ARM64 lazy storage helper")
                    }
                    let literal = instruction + 8
                    guard patched[literal] == nil || patched[literal] == entry else {
                        throw Failure.corrupted("conflicting lazy storage helper records")
                    }
                    patched[literal] = entry
                    binary.setUInt32(entry, at: literal)
                }
                output.append(try storageBindStream(bytes.subdata(in: record..<cursor), provider: provider))
                record = cursor; segment = nil; address = 0; targets.removeAll(keepingCapacity: true)
            case 0x10, 0x30: break
            case 0x20, 0x60: _ = try leb()
            case 0x40:
                while cursor < bytes.count && bytes[cursor] != 0 { cursor += 1 }
                guard cursor < bytes.count else { throw Failure.corrupted("lazy storage symbol") }
                cursor += 1
            case 0x50:
                guard opcode & 15 == 1 else { throw Failure.corrupted("non-pointer lazy storage bind") }
            case 0x70: segment = Int(opcode & 15); address = try leb()
            case 0x80: try advance(leb())
            case 0x90: try bind()
            case 0xa0:
                let skip = try leb(); try bind(); try advance(skip)
            case 0xb0: try bind(); try advance(UInt64(opcode & 15) * 8)
            case 0xc0:
                let count = try leb(), skip = try leb()
                guard count <= UInt64(binary.count / 8 - targets.count) else {
                    throw Failure.corrupted("lazy storage bind count")
                }
                for _ in 0..<count { try bind(); try advance(skip) }
            default: throw Failure.corrupted("unsupported lazy storage opcode")
            }
        }
        guard record == bytes.count else { throw Failure.corrupted("unterminated lazy storage record") }
        return output
    }

    private static func storageBindStream(_ bytes: Data, provider: (Int, String) throws -> Int) throws -> Data {
        var cursor = 0, ordinal = 0, emittedOrdinal = 0, symbol = "", output = Data()
        var changed = false
        func leb() throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<10 {
                guard cursor < bytes.count else { throw Failure.corrupted("storage bind operand") }
                let byte = bytes[cursor]; cursor += 1
                guard index != 9 || byte <= 1 else { throw Failure.corrupted("storage bind operand overflow") }
                value |= UInt64(byte & 127) << (index * 7)
                if byte < 128 { return value }
            }
            throw Failure.corrupted("storage bind operand overflow")
        }
        func setOrdinal(_ value: Int) -> Data {
            if value <= 0 { return Data([0x30 | UInt8(value & 15)]) }
            var result = Data([0x20]), rest = UInt64(value)
            repeat {
                let byte = UInt8(rest & 127); rest >>= 7
                result.append(byte | (rest == 0 ? 0 : 128))
            } while rest != 0
            return result
        }
        while cursor < bytes.count {
            let start = cursor, opcode = bytes[cursor]; cursor += 1
            switch opcode & 0xf0 {
            case 0x00: ordinal = 0; emittedOrdinal = 0; symbol = ""
            case 0x10: ordinal = Int(opcode & 15)
            case 0x20:
                let value = try leb()
                guard value <= UInt64(Int.max) else { throw Failure.corrupted("storage bind ordinal") }
                ordinal = Int(value)
            case 0x30: ordinal = opcode & 15 == 0 ? 0 : Int(opcode & 15) - 16
            case 0x40:
                let begin = cursor
                while cursor < bytes.count && bytes[cursor] != 0 { cursor += 1 }
                guard cursor < bytes.count, let value = String(data: bytes[begin..<cursor], encoding: .utf8) else {
                    throw Failure.corrupted("storage bind name")
                }
                symbol = value; cursor += 1
            case 0x50, 0x90, 0xb0: break
            case 0x60, 0x70, 0x80, 0xa0: _ = try leb()
            case 0xc0: _ = try leb(); _ = try leb()
            case 0xd0:
                if opcode & 15 == 0 { _ = try leb() }
                else if opcode & 15 != 1 { throw Failure.corrupted("storage threaded bind") }
            default: throw Failure.corrupted("storage bind opcode")
            }
            let binds = [UInt8(0x90), 0xa0, 0xb0, 0xc0].contains(opcode & 0xf0)
            let new = binds ? try provider(ordinal, symbol) : ordinal
            if binds && new != ordinal { changed = true }
            if binds && new != emittedOrdinal { output.append(setOrdinal(new)); emittedOrdinal = new }
            if ![UInt8(0x10), 0x20, 0x30].contains(opcode & 0xf0) { output.append(bytes[start..<cursor]) }
        }
        return changed ? output : bytes
    }

    /// Grow only LINKEDIT, placing fresh streams before the old signature. Existing code,
    /// fixups, strings and export offsets stay fixed; the staging signer replaces the old seal.
    private static func appendStorageBindStreams(_ streams: [(field: Int, bytes: Data)],
                                                commands: [LoadCommand], binary: inout Data) throws {
        guard let linkedit = commands.first(where: {
            $0.command == UInt32(LC_SEGMENT_64) && $0.size >= 72
                && String(data: binary[($0.offset + 8)..<($0.offset + 18)], encoding: .utf8) == "__LINKEDIT"
        }) else { throw Failure.corrupted("missing storage LINKEDIT") }
        let segment = linkedit.offset, fileOffset = binary.uint64(at: segment + 40)
        let fileSize = binary.uint64(at: segment + 48)
        guard fileOffset <= UInt64(binary.count), fileSize == UInt64(binary.count) - fileOffset else {
            throw Failure.corrupted("storage LINKEDIT is not last")
        }
        let signature = commands.first { $0.command == UInt32(LC_CODE_SIGNATURE) }
        var seal = Data()
        if let signature {
            guard signature.size >= 16 else { throw Failure.corrupted("storage signature command") }
            let offset = Int(binary.uint32(at: signature.offset + 8)), size = Int(binary.uint32(at: signature.offset + 12))
            if size > 0 {
                guard offset >= Int(fileOffset), offset <= binary.count, size == binary.count - offset else {
                    throw Failure.corrupted("storage signature is not last")
                }
                seal = binary.subdata(in: offset..<binary.count)
                binary.removeSubrange(offset..<binary.count)
            }
        }
        for stream in streams {
            binary.append(Data(count: (8 - binary.count % 8) % 8))
            guard binary.count <= Int(UInt32.max), stream.bytes.count <= Int(UInt32.max) else {
                throw Failure.corrupted("storage bind payload too large")
            }
            binary.setUInt32(UInt32(binary.count), at: stream.field)
            binary.setUInt32(UInt32(stream.bytes.count), at: stream.field + 4)
            binary.append(stream.bytes)
        }
        if let signature {
            binary.append(Data(count: (16 - binary.count % 16) % 16))
            guard binary.count <= Int(UInt32.max) else { throw Failure.corrupted("storage signature offset") }
            binary.setUInt32(UInt32(binary.count), at: signature.offset + 8)
            binary.append(seal)
        }
        let size = UInt64(binary.count) - fileOffset
        let oldVMSize = binary.uint64(at: segment + 32), address = binary.uint64(at: segment + 24)
        guard size <= UInt64.max - 0x3fff else { throw Failure.corrupted("storage LINKEDIT overflow") }
        let vmSize = max(oldVMSize, (size + 0x3fff) & ~UInt64(0x3fff))
        guard address <= UInt64.max - vmSize else { throw Failure.corrupted("storage LINKEDIT address overflow") }
        for command in commands where command.command == UInt32(LC_SEGMENT_64) && command.offset != segment {
            guard command.size >= 72 else { throw Failure.corrupted("storage segment command") }
            let other = binary.uint64(at: command.offset + 24)
            if other >= address && other < address + vmSize { throw Failure.corrupted("storage LINKEDIT overlaps segment") }
        }
        func set64(_ value: UInt64, at offset: Int) {
            Swift.withUnsafeBytes(of: value.littleEndian) { binary.replaceSubrange(offset..<(offset + 8), with: $0) }
        }
        set64(size, at: segment + 48); set64(vmSize, at: segment + 32)
    }
}
#endif
