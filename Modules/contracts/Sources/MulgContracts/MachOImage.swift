import Foundation
import MachO
import Darwin

/// Checked ARM64 image metadata shared by installation and runtime plugin preflight.
public enum MachOImage {
    /// Catalyst system frameworks may be redirected into iOSSupport or exist only in dyld's cache.
    public static func systemContains(_ path: String) -> Bool {
        typealias Contains = @convention(c) (UnsafePointer<CChar>) -> Bool
        let contains = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_dyld_shared_cache_contains_path")
            .map { unsafeBitCast($0, to: Contains.self) }
        let paths = path.hasPrefix("/System/Library/") ? ["/System/iOSSupport" + path, path] : [path]
        return paths.contains { candidate in
            FileManager.default.fileExists(atPath: candidate) || candidate.withCString { contains?($0) == true }
                || ((candidate.hasPrefix("/System/") || candidate.hasPrefix("/usr/lib/")) && dlopen_preflight(candidate))
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        case notMachO
        case noArm64Slice
        case corrupted(String)
        /// The load commands grew into the first section; the binary cannot be changed safely.
        case noRoomForLoadCommands
    }

    /// Whether the first four bytes of a file are a 64-bit Mach-O or a universal binary header.
    public static func isMachOHeader(_ prefix: some Collection<UInt8>) -> Bool {
        guard prefix.count >= 4 else { return false }
        let bytes = Array(prefix.prefix(4))
        let bigEndian = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        let littleEndian = bigEndian.byteSwapped
        return bigEndian == FAT_MAGIC || bigEndian == FAT_MAGIC_64 || littleEndian == MH_MAGIC_64
    }

    // MARK: Thinning

    /// The arm64 part of a universal binary, or the binary itself if it is already thin.
    public static func arm64Slice(of data: Data) throws -> Data {
        guard data.count >= 8 else { throw Failure.notMachO }
        let magic = data.bigEndianUInt32(at: 0)
        if magic == FAT_MAGIC || magic == FAT_MAGIC_64 {
            let is64 = magic == FAT_MAGIC_64
            let count = Int(data.bigEndianUInt32(at: 4))
            let entrySize = is64 ? 32 : 20  // fat_arch_64 / fat_arch
            var selected: Data?
            for index in 0..<count {
                let entry = 8 + index * entrySize
                guard entry + entrySize <= data.count else { throw Failure.corrupted("universal header") }
                guard Int32(bitPattern: data.bigEndianUInt32(at: entry)) == CPU_TYPE_ARM64 else { continue }
                // Newer system binaries add slices such as arm64e.x1 next to the plain ones: skip them.
                guard Self.supportedSubtypes.contains(data.bigEndianUInt32(at: entry + 4) & 0x00ff_ffff) else { continue }
                // Unsigned until checked: a damaged 64-bit header would trap in Int() or in offset + size.
                let rawOffset: UInt64
                let rawSize: UInt64
                if is64 {
                    rawOffset = data.bigEndianUInt64(at: entry + 8)
                    rawSize = data.bigEndianUInt64(at: entry + 16)
                } else {
                    rawOffset = UInt64(data.bigEndianUInt32(at: entry + 8))
                    rawSize = UInt64(data.bigEndianUInt32(at: entry + 12))
                }
                guard rawSize > 0, rawOffset <= UInt64(data.count), rawSize <= UInt64(data.count) - rawOffset else {
                    throw Failure.corrupted("arm64 slice outside the file")
                }
                let offset = Int(rawOffset)
                let size = Int(rawSize)
                let slice = data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + size)
                try validateARM64(slice)
                // Prefer ordinary ARM64 over ARM64e when both are present; never rewrite PAC ABI.
                if slice.uint32(at: 8) & 0x00ff_ffff == 0 { return slice }
                selected = slice
            }
            if let selected { return selected }
            throw Failure.noArm64Slice
        }
        guard data.uint32(at: 0) == MH_MAGIC_64 else { throw Failure.notMachO }
        try validateARM64(data)
        return data
    }

    /// ARM64 (all and v8) and ARM64e.
    private static let supportedSubtypes: Set<UInt32> = [0, 1, 2]

    private static func validateARM64(_ data: Data) throws {
        guard data.count >= headerSize, data.uint32(at: 0) == MH_MAGIC_64 else { throw Failure.notMachO }
        guard Int32(bitPattern: data.uint32(at: 4)) == CPU_TYPE_ARM64 else { throw Failure.noArm64Slice }
        guard supportedSubtypes.contains(data.uint32(at: 8) & 0x00ff_ffff) else {
            throw Failure.corrupted("unsupported ARM64 CPU subtype")
        }
    }

    // MARK: Load commands (thin, little-endian arm64 only)

    public struct LoadCommand: Equatable, Sendable {
        public let command: UInt32
        public let offset: Int
        public let size: Int
    }

    static let headerSize = MemoryLayout<mach_header_64>.size

    /// Every load command, checked against the header's declared size.
    public static func loadCommands(in binary: Data) throws -> [LoadCommand] {
        guard binary.count >= headerSize, binary.uint32(at: 0) == MH_MAGIC_64 else { throw Failure.notMachO }
        let count = Int(binary.uint32(at: 16))
        let commandsEnd = headerSize + Int(binary.uint32(at: 20))
        guard commandsEnd <= binary.count else { throw Failure.corrupted("load commands past end of file") }
        var commands: [LoadCommand] = []
        var offset = headerSize
        for index in 0..<count {
            guard offset + 8 <= commandsEnd else { throw Failure.corrupted("load command \(index)") }
            let command = binary.uint32(at: offset)
            let size = Int(binary.uint32(at: offset + 4))
            guard size >= minimumSize(of: command), size % 8 == 0, offset + size <= commandsEnd else {
                throw Failure.corrupted("load command \(index)")
            }
            commands.append(LoadCommand(command: command, offset: offset, size: size))
            offset += size
        }
        guard offset == commandsEnd else { throw Failure.corrupted("load command size total") }
        return commands
    }

    /// The smallest size of the commands whose fields are read here, so a damaged game can't
    /// make a read run past the file and crash the app.
    static func minimumSize(of command: UInt32) -> Int {
        switch command {
        case UInt32(LC_SEGMENT_64): 72
        case UInt32(LC_BUILD_VERSION), UInt32(LC_ENCRYPTION_INFO_64), UInt32(LC_LOAD_DYLIB), UInt32(LC_LOAD_WEAK_DYLIB), UInt32(LC_REEXPORT_DYLIB), UInt32(LC_LOAD_UPWARD_DYLIB), UInt32(LC_LAZY_LOAD_DYLIB): 24
        case UInt32(LC_RPATH): 12
        case UInt32(LC_VERSION_MIN_IPHONEOS), UInt32(LC_VERSION_MIN_MACOSX): 16
        default: 8
        }
    }

    public struct Dependency: Sendable, Equatable {
        public let path: String
        public let weak: Bool
    }

    public static func dependencies(in binary: Data) throws -> [Dependency] {
        try loadCommands(in: binary).filter { isDylibLoad($0.command) }.map { command in
            let data = binary.subdata(in: (binary.startIndex + command.offset)..<(binary.startIndex + command.offset + command.size))
            let prefix = try dylibPrefixSize(in: data)
            guard let name = commandString(in: data, minimumOffset: prefix), !name.isEmpty else {
                throw Failure.corrupted("invalid dylib name")
            }
            return Dependency(path: name, weak: command.command == UInt32(LC_LOAD_WEAK_DYLIB)
                              || (prefix == 28 && data.uint32(at: 24) & 1 != 0))
        }
    }

    /// Modern dylib-use commands carry flags after the version fields. The marker occupies
    /// the legacy timestamp field; preserve this whole prefix when changing the path.
    public static func dylibPrefixSize(in command: Data) throws -> Int {
        guard command.count >= 24 else { throw Failure.corrupted("truncated dylib command") }
        if command.uint32(at: 12) == 0x1a74_1800 {
            guard [UInt32(LC_LOAD_DYLIB), UInt32(LC_LOAD_WEAK_DYLIB)].contains(command.uint32(at: 0)),
                  command.count >= 28, command.uint32(at: 8) == 28 else {
                throw Failure.corrupted("invalid dylib-use command")
            }
            return 28
        }
        return 24
    }

    public static func runpaths(in binary: Data) throws -> [String] {
        try loadCommands(in: binary).filter { $0.command == UInt32(LC_RPATH) }.map { command in
            let data = binary.subdata(in: (binary.startIndex + command.offset)..<(binary.startIndex + command.offset + command.size))
            guard let path = commandString(in: data, minimumOffset: 12) else {
                throw Failure.corrupted("invalid runpath")
            }
            return path
        }
    }

    public static func isDylibLoad(_ command: UInt32) -> Bool {
        [UInt32(LC_LOAD_DYLIB), UInt32(LC_LOAD_WEAK_DYLIB), UInt32(LC_REEXPORT_DYLIB),
         UInt32(LC_LOAD_UPWARD_DYLIB), UInt32(LC_LAZY_LOAD_DYLIB)].contains(command)
    }

    public static func commandString(in command: Data, minimumOffset: Int) -> String? {
        guard command.count >= 12 else { return nil }
        let nameOffset = Int(command.uint32(at: 8))
        guard nameOffset >= minimumOffset, nameOffset < command.count else { return nil }
        let tail = command[(command.startIndex + nameOffset)...]
        guard let end = tail.firstIndex(of: 0) else { return nil }
        return String(data: tail[..<end], encoding: .utf8)
    }

}

extension Data {
    func uint32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { copyBytes(to: $0, from: (startIndex + offset)..<(startIndex + offset + 4)) }
        return UInt32(littleEndian: value)
    }

    func uint64(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { copyBytes(to: $0, from: (startIndex + offset)..<(startIndex + offset + 8)) }
        return UInt64(littleEndian: value)
    }

    func bigEndianUInt32(at offset: Int) -> UInt32 { uint32(at: offset).byteSwapped }
    func bigEndianUInt64(at offset: Int) -> UInt64 { uint64(at: offset).byteSwapped }

}
