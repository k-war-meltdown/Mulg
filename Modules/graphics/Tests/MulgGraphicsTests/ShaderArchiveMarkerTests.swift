import Foundation
@testable import MulgGraphics
import Testing

@Suite("Shader archive unsupported marker")
struct ShaderArchiveMarkerTests {
    private func marker(_ content: String?) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("marker-\(UUID().uuidString).unsupported")
        if let content { try Data(content.utf8).write(to: url) }
        return url
    }

    @Test("A marker for this game build skips the doomed archive work")
    func sameBuildIsUnsupported() throws {
        let url = try marker("1242")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(GraphicsModule.archiveUnsupported(marker: url, gameBuild: "1242"))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("A game update retries, and the stale marker is removed")
    func anotherBuildRetries() throws {
        let url = try marker("1242")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!GraphicsModule.archiveUnsupported(marker: url, gameBuild: "1243"))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("No marker means capture is attempted")
    func missingMarker() throws {
        #expect(!GraphicsModule.archiveUnsupported(marker: try marker(nil), gameBuild: "1242"))
    }
}
