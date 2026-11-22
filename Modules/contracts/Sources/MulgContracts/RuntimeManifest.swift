import Foundation

/// Shared build stamp for the runtime and bridge. Written before code signing.
public struct RuntimeManifest: Codable, Sendable, Equatable {
    public let version: String
    public let runtimeProtocol: Int

    public init(version: String = MulgVersion.current, runtimeProtocol: Int = MulgVersion.runtimeProtocol) {
        self.version = version
        self.runtimeProtocol = runtimeProtocol
    }

    public static let fileName = "MulgRuntime.json"
    public static func frameworkURL(_ framework: URL) -> URL {
        let versioned = FileManager.default.fileExists(atPath: framework.appendingPathComponent("Versions").path)
        return framework.appendingPathComponent(versioned ? "Resources/" + fileName : fileName)
    }
    public static func read(at url: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
