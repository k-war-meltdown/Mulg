// Host-side module: the Mulg app is a native macOS app, never Mac Catalyst.
#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import Darwin
import MachO
import MulgContracts

/// Reads and rewrites the Mach-O binaries of an iOS game so macOS runs them as Mac Catalyst
/// code (PLAN.md §16.1). Port of upstream `Utils/Macho.swift`, working on in-memory data so
/// every step is testable.
///
/// Changes from upstream:
/// - 64-bit universal headers (`FAT_MAGIC_64`) are recognised (§16.3 E9);
/// - the game's own SDK version can be kept instead of stamping SDK 14.0 (§16.4 X1);
/// - a rewrite that would overwrite data after the load commands is an error, not a log line;
/// - the runtime's load command is added here, replacing the vendored `inject` package.
public enum MachOBinary {
    public typealias Failure = MachOImage.Failure

    /// Mac Catalyst version numbers match iOS version numbers (both 14.0 and later).
    public struct Version: Equatable, Sendable, CustomStringConvertible {
        public let packed: UInt32

        public init(packed: UInt32) { self.packed = packed }
        public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) {
            packed = UInt32(major) << 16 | UInt32(minor & 0xff) << 8 | UInt32(patch & 0xff)
        }

        public var major: Int { Int(packed >> 16) }
        public var description: String { "\(major).\((packed >> 8) & 0xff)" }
    }

    /// What the binary says it was built for.
    public struct BuildInfo: Equatable, Sendable {
        public let platform: UInt32
        public let minimumOS: Version
        public let sdk: Version
    }

    /// Product deployment floor; the legacy SDK stamp remains available for game compatibility.
    public static let catalystMinimumOS = Version(27)
    public static let defaultSDK = Version(14)

    // MARK: Recognising binaries

    public typealias LoadCommand = MachOImage.LoadCommand
    static let headerSize = MemoryLayout<mach_header_64>.size
    public static func isMachOHeader(_ prefix: some Collection<UInt8>) -> Bool { MachOImage.isMachOHeader(prefix) }
    public static func arm64Slice(of data: Data) throws -> Data { try MachOImage.arm64Slice(of: data) }
    public static func loadCommands(in binary: Data) throws -> [LoadCommand] { try MachOImage.loadCommands(in: binary) }

    /// Whether the App Store encryption is still on. Encrypted games cannot run and are refused.
    public static func isEncrypted(_ binary: Data) throws -> Bool {
        for command in try loadCommands(in: binary) where command.command == UInt32(LC_ENCRYPTION_INFO_64) {
            // encryption_info_command_64: cmd, cmdsize, cryptoff, cryptsize, cryptid
            return binary.uint32(at: command.offset + 16) != 0
        }
        return false
    }

    /// The platform, minimum OS and SDK from `LC_BUILD_VERSION` or an older
    /// `LC_VERSION_MIN_*` command.
    public static func buildInfo(of binary: Data) throws -> BuildInfo? {
        for command in try loadCommands(in: binary) {
            switch command.command {
            case UInt32(LC_BUILD_VERSION):
                return BuildInfo(platform: binary.uint32(at: command.offset + 8),
                                 minimumOS: Version(packed: binary.uint32(at: command.offset + 12)),
                                 sdk: Version(packed: binary.uint32(at: command.offset + 16)))
            case UInt32(LC_VERSION_MIN_IPHONEOS):
                return BuildInfo(platform: UInt32(PLATFORM_IOS),
                                 minimumOS: Version(packed: binary.uint32(at: command.offset + 8)),
                                 sdk: Version(packed: binary.uint32(at: command.offset + 12)))
            case UInt32(LC_VERSION_MIN_MACOSX):
                return BuildInfo(platform: UInt32(PLATFORM_MACOS),
                                 minimumOS: Version(packed: binary.uint32(at: command.offset + 8)),
                                 sdk: Version(packed: binary.uint32(at: command.offset + 12)))
            default:
                continue
            }
        }
        return nil
    }

    /// The paths of every `LC_LOAD_DYLIB` and `LC_LOAD_WEAK_DYLIB`.
    public static func loadedLibraries(in binary: Data) throws -> [String] {
        try dependencies(in: binary).map(\.path)
    }

    public typealias Dependency = MachOImage.Dependency
    public static func dependencies(in binary: Data) throws -> [Dependency] { try MachOImage.dependencies(in: binary) }
    public static func runpaths(in binary: Data) throws -> [String] { try MachOImage.runpaths(in: binary) }

    // MARK: Rewriting

    /// Relabels the binary as Mac Catalyst. The SDK is the game's own when `keepSDK` is set
    /// and the game states one newer than upstream's stamp, otherwise 14.0.
    public static func convertToCatalyst(_ binary: inout Data, keepSDK: Bool) throws {
        let info = try buildInfo(of: binary)
        // Some repackaged IPAs contain empty SDK placeholder dylibs stamped iOS 100.0.
        // Repair only that inconsistent, code-free case; real deployment floors survive.
        let emptyPlaceholder = try hasPlaceholderDeployment(in: binary, build: info)
        let minimum = emptyPlaceholder ? catalystMinimumOS.packed
            : max(catalystMinimumOS.packed, info?.minimumOS.packed ?? 0)
        let sdk = keepSDK ? Version(packed: max(defaultSDK.packed, info?.sdk.packed ?? 0)) : defaultSDK
        var command = Data()
        command.appendUInt32(UInt32(LC_BUILD_VERSION))
        command.appendUInt32(24)
        command.appendUInt32(UInt32(PLATFORM_MACCATALYST))
        command.appendUInt32(minimum)
        command.appendUInt32(sdk.packed)
        command.appendUInt32(0)  // ntools
        let versionCommands: Set<UInt32> = [UInt32(LC_BUILD_VERSION), UInt32(LC_VERSION_MIN_IPHONEOS),
                                            UInt32(LC_VERSION_MIN_MACOSX)]
        try rewriteCommands(&binary) { commands in
            if let existing = commands.first(where: { $0.command == UInt32(LC_BUILD_VERSION) }) {
                command = existing.data
                let tools = command.uint32(at: 20)
                guard UInt64(tools) * 8 <= UInt64(command.count - 24) else {
                    throw Failure.corrupted("build tool records")
                }
                command.setUInt32(UInt32(PLATFORM_MACCATALYST), at: 8)
                command.setUInt32(minimum, at: 12)
                command.setUInt32(sdk.packed, at: 16)
            }
            commands.removeAll { versionCommands.contains($0.command) }
            commands.append((UInt32(LC_BUILD_VERSION), command))
        }
    }

    /// A placeholder has no code, data, initializers or symbols, and only header padding
    /// in its executable segment. Never lower a deployment requirement on an actual SDK.
    private static func hasPlaceholderDeployment(in binary: Data, build: BuildInfo?) throws -> Bool {
        guard let build, build.platform == UInt32(PLATFORM_IOS),
              build.minimumOS == Version(100), build.sdk.packed >= defaultSDK.packed,
              build.sdk.packed <= catalystMinimumOS.packed,
              binary.uint32(at: 12) == UInt32(MH_DYLIB) else { return false }
        let commands = try loadCommands(in: binary)
        let headerEnd = headerSize + Int(binary.uint32(at: 20))
        var hasText = false
        for command in commands {
            let base = command.offset
            switch command.command {
            case UInt32(LC_SEGMENT_64):
                let count = Int(binary.uint32(at: base + 64))
                guard count <= (command.size - 72) / 80 else { throw Failure.corrupted("section table") }
                for index in 0..<count where binary.uint64(at: base + 72 + index * 80 + 40) != 0 {
                    return false
                }
                let name = String(decoding: binary[(base + 8)..<(base + 24)].prefix { $0 != 0 }, as: UTF8.self)
                if name == "__TEXT" {
                    let size = binary.uint64(at: base + 48)
                    guard binary.uint64(at: base + 40) == 0,
                          size >= UInt64(headerEnd), size <= UInt64(binary.count),
                          binary[headerEnd..<Int(size)].allSatisfy({ $0 == 0 }) else { return false }
                    hasText = true
                } else if name != "__LINKEDIT" { return false }
            case UInt32(LC_SYMTAB):
                guard command.size >= 24 else { throw Failure.corrupted("symbol table") }
                if binary.uint32(at: base + 12) != 0 { return false }
            case UInt32(LC_ROUTINES), UInt32(LC_ROUTINES_64), UInt32(LC_MAIN), UInt32(LC_UNIXTHREAD):
                return false
            default: break
            }
        }
        return hasText
    }
    /// Points `@rpath/<name>` at another path, for example libswiftUIKit at the copy in
    /// /System/iOSSupport. Does nothing if the binary does not load it.
    public static func replaceLibrary(_ binary: inout Data, from old: String, to new: String) throws {
        try rewriteCommands(&binary) { commands in
            for index in commands.indices where isDylibLoad(commands[index].command) {
                guard dylibName(in: commands[index].data) == old else { continue }
                commands[index].data = try dylibCommand(commands[index].command, path: new,
                                                    copyingVersionsFrom: commands[index].data)
            }
        }
    }

    /// Adds a load command for `path` unless the binary already loads it.
    public static func addLibrary(_ binary: inout Data, path: String) throws {
        guard try !loadedLibraries(in: binary).contains(path) else { return }
        try rewriteCommands(&binary) { commands in
            commands.append((UInt32(LC_LOAD_DYLIB), try dylibCommand(UInt32(LC_LOAD_DYLIB), path: path)))
        }
    }

    /// Used by host injection, refresh and removal; validation completes before the file changes.
    public static func editLibraries(at file: URL, adding: [String] = [], removing: [String] = [],
                                     replacing: [String: String] = [:]) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        // This buffer is edited in place; mapped Foundation storage can be read-only.
        var binary = try arm64Slice(of: Data(contentsOf: file))
        let libraries = try loadedLibraries(in: binary)
        let removed = Set(libraries.enumerated().compactMap { index, path in
            removing.contains(path) && replacing[path] == nil ? index + 1 : nil
        })
        try remapLibraryOrdinals(&binary, removing: removed, count: libraries.count)
        try rewriteCommands(&binary) { commands in
            commands.removeAll { isDylibLoad($0.command) && removing.contains(dylibName(in: $0.data) ?? "")
                && replacing[dylibName(in: $0.data) ?? ""] == nil }
            for index in commands.indices where isDylibLoad(commands[index].command) {
                if let old = dylibName(in: commands[index].data), let new = replacing[old] {
                    commands[index].data = try dylibCommand(commands[index].command, path: new, copyingVersionsFrom: commands[index].data)
                }
            }
        }
        for path in adding {
            guard !path.utf8.contains(0) else { throw Failure.corrupted("library path contains NUL") }
            try addLibrary(&binary, path: path)
        }
        try binary.write(to: file, options: .atomic)
        if let mode = attributes[.posixPermissions] {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        }
    }

    /// Some system framework aliases do not resolve although their versioned image
    /// is available. Probe only Apple system paths, without loading or running code.
    /// Keep library order and weak/strong flags so import ordinals remain unchanged.
    @discardableResult
    static func repairSystemFrameworkPaths(_ binary: inout Data,
        isLoadable: (String) -> Bool = { dlopen_preflight($0) },
        currentVersion: (String) -> String? = {
            try? FileManager.default.destinationOfSymbolicLink(atPath: $0 + "/Versions/Current")
        }) throws -> Bool {
        var updated = binary
        for path in try loadedLibraries(in: binary) {
            guard path.hasPrefix("/System/Library/Frameworks/") || path.hasPrefix("/System/Library/PrivateFrameworks/"),
                  !path.split(separator: "/").contains(".."), !isLoadable(path) else { continue }
            let url = URL(fileURLWithPath: path), framework = url.deletingLastPathComponent()
            guard framework.pathExtension == "framework",
                  framework.deletingPathExtension().lastPathComponent == url.lastPathComponent else { continue }
            for root in ["/System/iOSSupport" + framework.path, framework.path] {
                guard let version = currentVersion(root), !version.isEmpty,
                      version != ".", version != "..", !version.contains("/") else { continue }
                let candidate = root + "/Versions/" + version + "/" + url.lastPathComponent
                guard isLoadable(candidate) else { continue }
                try replaceLibrary(&updated, from: path, to: candidate)
                break
            }
        }
        guard updated != binary else { return false }
        binary = updated
        return true
    }

    /// Libraries that must come from the system rather than the game (upstream list).
    public static let systemSwiftLibraries = ["libswiftUIKit"]

    /// The whole per-binary conversion upstream's installer runs: thin, relabel, relink.
    public static func convertForMac(_ data: Data, keepSDK: Bool) throws -> Data {
        var binary = try arm64Slice(of: data)
        guard let build = try buildInfo(of: binary) else { throw Failure.corrupted("missing build platform") }
        switch build.platform {
        case UInt32(PLATFORM_MACOS), UInt32(PLATFORM_MACCATALYST): return binary
        case UInt32(PLATFORM_IOS): break
        default: throw Failure.corrupted("unsupported source platform \(build.platform)")
        }
        try convertToCatalyst(&binary, keepSDK: keepSDK)
        try repairSystemFrameworkPaths(&binary)
        for library in systemSwiftLibraries {
            // iOS SDKs use both runpath and absolute install names. Catalyst's UIKit
            // overlay lives in iOSSupport for either form; validating a fallback alone
            // would leave dyld trying the unavailable iOS path at launch.
            let destination = "/System/iOSSupport/usr/lib/swift/\(library).dylib"
            for source in ["@rpath/\(library).dylib", "/usr/lib/swift/\(library).dylib"] {
                try replaceLibrary(&binary, from: source, to: destination)
            }
        }
        return binary
    }

    // MARK: Helpers

    private static func isDylibLoad(_ command: UInt32) -> Bool { MachOImage.isDylibLoad(command) }
    private static func dylibName(in command: Data) -> String? {
        guard command.count >= 24 else { return nil }
        return MachOImage.commandString(in: command, minimumOffset: 24)
    }

    /// A dylib_command: cmd, cmdsize, name offset, timestamp, current and compatibility
    /// version, then the path padded with zeros to 8 bytes.
    private static func dylibCommand(_ type: UInt32, path: String, copyingVersionsFrom old: Data? = nil) throws -> Data {
        guard !path.utf8.contains(0) else { throw Failure.corrupted("library path contains NUL") }
        let fixed = try old.map { try MachOImage.dylibPrefixSize(in: $0) } ?? 24
        let pathBytes = Array(path.utf8)
        let size = (fixed + pathBytes.count + 1 + 7) / 8 * 8
        var data = Data()
        data.appendUInt32(type)
        data.appendUInt32(UInt32(size))
        data.appendUInt32(UInt32(fixed))
        if let old, old.count >= fixed {
            data.append(old[(old.startIndex + 12)..<(old.startIndex + fixed)])
        } else {
            data.appendUInt32(2)            // timestamp, as ld writes it
            data.appendUInt32(0x0001_0000)  // current version 1.0
            data.appendUInt32(0x0001_0000)  // compatibility version 1.0
        }
        data.append(contentsOf: pathBytes)
        data.append(Data(count: size - data.count))
        return data
    }

    /// Lets `edit` change the list of load commands, then writes them back. The space after
    /// the load commands (up to the first section) must be zeros where the list grows.
    private static func rewriteCommands(_ binary: inout Data,
                                        _ edit: (inout [(command: UInt32, data: Data)]) throws -> Void) throws {
        let existing = try loadCommands(in: binary)
        _ = try dependencies(in: binary)
        let oldEnd = headerSize + Int(binary.uint32(at: 20))
        let limit = try payloadLimit(in: binary, commands: existing, headerEnd: oldEnd)
        var commands = existing.map { command in
            (command: command.command,
             data: binary.subdata(in: binary.startIndex + command.offset ..< binary.startIndex + command.offset + command.size))
        }
        try edit(&commands)

        let newBody = commands.reduce(into: Data()) { $0.append($1.data) }
        let newEnd = headerSize + newBody.count
        if newEnd > oldEnd {
            guard newEnd <= limit,
                  binary[(binary.startIndex + oldEnd)..<(binary.startIndex + newEnd)].allSatisfy({ $0 == 0 }) else {
                throw Failure.noRoomForLoadCommands
            }
        }
        var body = newBody
        if newEnd < oldEnd {
            body.append(Data(count: oldEnd - newEnd))
        }
        binary.replaceSubrange((binary.startIndex + headerSize)..<(binary.startIndex + headerSize + body.count), with: body)
        binary.setUInt32(UInt32(commands.count), at: 16)
        binary.setUInt32(UInt32(newBody.count), at: 20)
    }

    /// Declared file data is occupied even when all its bytes are zero. The header-bearing
    /// segment may contain header padding; other segment data and all metadata bound growth.
    private static func payloadLimit(in binary: Data, commands: [LoadCommand], headerEnd: Int) throws -> Int {
        var limit = binary.count
        func protect(_ offset: UInt64, _ size: UInt64) throws {
            guard size > 0 else { return }
            guard offset <= UInt64(binary.count), size <= UInt64(binary.count) - offset,
                  offset >= UInt64(headerEnd) else { throw Failure.corrupted("file payload range") }
            limit = min(limit, Int(offset))
        }
        for command in commands {
            let base = command.offset
            func require(_ bytes: Int) throws {
                guard command.size >= bytes else { throw Failure.corrupted("truncated file-data command") }
            }
            func range(_ offsetField: Int, _ sizeField: Int, stride: UInt64 = 1) throws {
                try protect(UInt64(binary.uint32(at: base + offsetField)), UInt64(binary.uint32(at: base + sizeField)) * stride)
            }
            switch command.command {
            case UInt32(LC_SEGMENT_64):
                let count = Int(binary.uint32(at: base + 64))
                guard count <= (command.size - 72) / 80 else { throw Failure.corrupted("section table") }
                let offset = binary.uint64(at: base + 40), size = binary.uint64(at: base + 48)
                guard offset <= UInt64(binary.count), size <= UInt64(binary.count) - offset else {
                    throw Failure.corrupted("segment file range")
                }
                if offset > 0 { try protect(offset, size) }
                else if size > 0 && count == 0 { limit = min(limit, headerEnd) }
                for index in 0..<count {
                    let section = base + 72 + index * 80
                    let type = binary.uint32(at: section + 64) & 0xff
                    if ![UInt32(1), 12, 18].contains(type) { // zero-fill sections have no file data
                        try protect(UInt64(binary.uint32(at: section + 48)), binary.uint64(at: section + 40))
                    }
                    try protect(UInt64(binary.uint32(at: section + 56)), UInt64(binary.uint32(at: section + 60)) * 8)
                }
            case UInt32(LC_SYMTAB):
                try require(24)
                try range(8, 12, stride: 16)
                try range(16, 20)
            case UInt32(LC_DYSYMTAB):
                try require(80)
                for (offset, size, stride) in [(32, 36, UInt64(8)), (40, 44, 56), (48, 52, 4),
                                              (56, 60, 4), (64, 68, 8), (72, 76, 8)] {
                    try range(offset, size, stride: stride)
                }
            case UInt32(LC_SYMSEG):
                try require(16)
                try range(8, 12)
            case UInt32(LC_DYLD_INFO), UInt32(LC_DYLD_INFO_ONLY):
                try require(48)
                for offset in Swift.stride(from: 8, to: 48, by: 8) { try range(offset, offset + 4) }
            case UInt32(LC_CODE_SIGNATURE), UInt32(LC_SEGMENT_SPLIT_INFO), UInt32(LC_FUNCTION_STARTS),
                 UInt32(LC_DATA_IN_CODE), UInt32(LC_DYLIB_CODE_SIGN_DRS), UInt32(LC_LINKER_OPTIMIZATION_HINT),
                 UInt32(LC_DYLD_EXPORTS_TRIE), UInt32(LC_DYLD_CHAINED_FIXUPS), UInt32(LC_ATOM_INFO),
                 UInt32(LC_FUNCTION_VARIANTS), UInt32(LC_FUNCTION_VARIANT_FIXUPS):
                try require(16)
                try range(8, 12)
            case UInt32(LC_ENCRYPTION_INFO_64):
                try range(8, 12)
            case UInt32(LC_TWOLEVEL_HINTS):
                try require(16)
                try range(8, 12, stride: 4)
            case UInt32(LC_NOTE):
                try require(40)
                try protect(binary.uint64(at: base + 24), binary.uint64(at: base + 32))
            case UInt32(LC_MAIN):
                try require(24)
                let offset = binary.uint64(at: base + 8)
                if offset > 0 { try protect(offset, 1) }
            case UInt32(LC_FILESET_ENTRY):
                try require(32)
                let offset = binary.uint64(at: base + 16)
                if offset > 0 { try protect(offset, 1) }
            case UInt32(LC_SEGMENT):
                throw Failure.corrupted("32-bit segment in ARM64 image")
            default: break
            }
        }
        return limit
    }
}

// MARK: - Byte access

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

    mutating func appendUInt32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func setUInt32(_ value: UInt32, at offset: Int) {
        Swift.withUnsafeBytes(of: value.littleEndian) { replaceSubrange((startIndex + offset)..<(startIndex + offset + 4), with: $0) }
    }

}
#endif
