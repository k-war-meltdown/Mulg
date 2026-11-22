//
//  Macho.swift
//  Mulg
//

import Foundation
import MulgLibrary

class Macho {
    /// The arm64 part of a universal file (classic or 64-bit); a thin file stays as it is.
    static func stripBinary(_ binary: inout Data) throws {
        guard binary.count >= 4 else { return }
        let magic = binary.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard [FAT_CIGAM, FAT_CIGAM_64].contains(magic) else { return }
        do {
            binary = try MachOBinary.arm64Slice(of: binary)
        } catch MachOBinary.Failure.noArm64Slice {
            throw MulgError.failedToStripBinary
        }
    }

    /// Thins, relabels as Mac Catalyst and relinks one binary with the library module's
    /// `MachOBinary`, which also reads 64-bit universal files and refuses a rewrite that would
    /// overwrite code. `keepSDK` keeps the game's own SDK version instead of 14.0 (PLAN.md §16.4 X1).
    static func convertMacho(_ macho: URL, keepSDK: Bool = false) throws {
        let binary = try Data(contentsOf: macho, options: .alwaysMapped)
        try MachOBinary.convertForMac(binary, keepSDK: keepSDK).write(to: macho, options: .atomic)
    }

    static func isMachoEncrypted(atURL url: URL) throws -> Bool {
        let binary = try MachOBinary.arm64Slice(of: Data(contentsOf: url, options: .alwaysMapped))
        return try MachOBinary.isEncrypted(binary)
    }

    static func isMachoValidArch(_ url: URL) throws -> Bool {
        let binary = try MachOBinary.arm64Slice(of: Data(contentsOf: url, options: .alwaysMapped))
        return try MachOBinary.buildInfo(of: binary)?.platform == UInt32(PLATFORM_MACCATALYST)
    }
}
