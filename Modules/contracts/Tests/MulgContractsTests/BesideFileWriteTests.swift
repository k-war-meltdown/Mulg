import Foundation
import Testing
@testable import MulgContracts

/// Mulg's in-game saves never use a temporary folder: with moved game data it was on another drive (2026-10-17).
@Suite("Writes beside the destination")
struct BesideFileWriteTests {
    @Test func replacesInPlaceAndLeavesNoTemporary() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("default.plist")
        try Data("one".utf8).writeBeside(to: file)
        try Data("two".utf8).writeBeside(to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "two")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["default.plist"])
    }

    @Test func failureKeepsTheOldFileAndCleansUp() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("default.plist")
        try Data("old".utf8).writeBeside(to: file)
        let blocked = folder.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: blocked.appendingPathComponent("inside"), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try Data("x".utf8).writeBeside(to: blocked) }  // a non-empty folder cannot be replaced
        #expect(try String(contentsOf: file, encoding: .utf8) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["blocked", "default.plist"])
    }
}
