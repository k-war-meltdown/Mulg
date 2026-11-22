import Foundation
@testable import MulgEngine
import Testing

private struct EncodingThreadProbe: Encodable, Sendable {
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Thread.isMainThread)
    }
}

@Suite("Background report writer")
struct ReportWriterTests {
    @Test @MainActor func valueSnapshotsKeepJSONTypesAndEncodeOnTheWriterQueue() throws {
        let writer = ReportWriter(), directory = folder()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let file = directory.appendingPathComponent("input.json")
        writer.writeJSONObject(["unsigned": UInt64.max, "signed": Int64.min, "flag": true,
                               "nested": ["state": "camera"], "empty": NSNull()], to: file)
        writer.flush()
        struct Snapshot: Decodable {
            let unsigned: UInt64, signed: Int64, flag: Bool
            let nested: [String: String]
            let empty: String?
        }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
        #expect(snapshot.unsigned == UInt64.max && snapshot.signed == Int64.min)
        #expect(snapshot.flag && snapshot.nested == ["state": "camera"] && snapshot.empty == nil)
        let original = try Data(contentsOf: file)
        writer.writeJSONObject(["invalid": Double.nan], to: file)
        writer.flush()
        #expect(try Data(contentsOf: file) == original)
        writer.writeSnapshot(EncodingThreadProbe(), to: file)
        writer.flush()
        #expect(try JSONDecoder().decode(Bool.self, from: Data(contentsOf: file)) == false)
    }

    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Diagnostics")
    }

    @Test("Writes create the folder, and the newest content of a file wins")
    func newestWins() throws {
        let writer = ReportWriter(), directory = folder()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let file = directory.appendingPathComponent("report.json")
        for index in 0..<50 { writer.write(Data("\(index)".utf8), to: file) }
        writer.flush()
        #expect(try String(contentsOf: file, encoding: .utf8) == "49")
    }

    @Test("Unchanged content is skipped while the file exists, and rewritten once it is gone")
    func skipsUnchanged() throws {
        let writer = ReportWriter(), directory = folder()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let file = directory.appendingPathComponent("report.json")
        writer.write(["a": 1], to: file)
        writer.flush()
        let first = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.02)
        writer.write(["a": 1], to: file)
        writer.flush()
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == first)

        try FileManager.default.removeItem(at: directory)
        writer.write(["a": 1], to: file)
        writer.flush()
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
