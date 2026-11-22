import Foundation

/// An early failure precedes the session lease. The host only accepts evidence
/// for the process and launch it just started, never an older report.
public struct RuntimeStartupFailure: Codable, Sendable {
    public let processIdentifier: Int32
    public let bundleIdentifier: String
    public let recordedAt: Date
    public let message: String

    public init(processIdentifier: Int32, bundleIdentifier: String, message: String) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.recordedAt = Date()
        self.message = message
    }

    private static func file(paths: ContainerPaths, bundleIdentifier: String) -> URL {
        paths.diagnosticsDirectory(for: bundleIdentifier).appendingPathComponent("runtime-startup-failure.json")
    }

    /// One synchronous launch-only write: the process exits before a background
    /// writer could be guaranteed to finish. No frame/render callback uses this.
    public func save(paths: ContainerPaths) throws {
        let url = Self.file(paths: paths, bundleIdentifier: bundleIdentifier)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).writeBeside(to: url)
    }

    public static func current(paths: ContainerPaths, bundleIdentifier: String,
                               processIdentifier: Int32, startedAt: Date) -> RuntimeStartupFailure? {
        guard let data = try? Data(contentsOf: file(paths: paths, bundleIdentifier: bundleIdentifier)),
              let report = try? JSONDecoder().decode(Self.self, from: data),
              report.bundleIdentifier == bundleIdentifier, report.processIdentifier == processIdentifier,
              report.recordedAt >= startedAt else { return nil }
        return report
    }
}
