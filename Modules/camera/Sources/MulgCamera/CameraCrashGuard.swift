import Foundation
import MulgEngine

/// Camera reach changes values inside the game. A game that crashes while they are changed (a
/// render thread meeting a camera it was not built for: Genshin, 2026-10-09, four minutes after
/// 15 limits were raised) must not crash the same way on every launch: safe mode only counts
/// launches that end within 30 seconds, so a later crash never turned the feature off.
/// A marker exists while limits are changed; a clean close removes it. Found at the next launch,
/// it means the last session ended with them changed, and camera reach is switched off.
@MainActor
enum CameraCrashGuard {
    static let fileName = "camera-reach-active"

    static func marker(_ context: ModuleContext) -> URL {
        context.paths.diagnosticsDirectory(for: context.bundleIdentifier).appendingPathComponent(fileName)
    }

    static func markActive(_ context: ModuleContext) {
        let url = marker(context)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().writeBeside(to: url)
    }

    static func clear(_ context: ModuleContext) {
        try? FileManager.default.removeItem(at: marker(context))
    }

    /// At start-up: true when the previous session ended while camera reach had changed the game.
    static func previousSessionCrashed(_ context: ModuleContext) -> Bool {
        FileManager.default.fileExists(atPath: marker(context).path)
    }
}
