#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import Foundation
import MulgContracts

/// Captures the launch display once in the host. No game-side observers or live resolution changes.
public enum DesktopLaunchResolution {
    public struct Snapshot: Sendable, Equatable {
        public let width: Int
        public let height: Int
        public let scale: Double

        /// Native fullscreen keeps the camera/notch safe area outside its content. Do not subtract
        /// the desktop's menu bar or Dock, which disappear in fullscreen.
        public init?(size: CGSize, scale: CGFloat, safeAreaTop: CGFloat = 0) {
            let height = size.height - safeAreaTop
            guard size.width.isFinite, height.isFinite, scale.isFinite, safeAreaTop.isFinite,
                  safeAreaTop >= 0, size.width >= 2, height >= 2, size.width <= 16384, height <= 16384, scale > 0,
                  size.width * scale <= 16384, height * scale <= 16384,
                  size.width * scale >= 2, height * scale >= 2 else { return nil }
            self.width = Int(size.width.rounded())
            self.height = Int(height.rounded())
            self.scale = Double(scale)
        }
    }

    /// Called immediately before starting a stopped game, while its launch lease is held.
    /// NSScreen.main follows the display containing the launcher's active window.
    @MainActor
    @discardableResult
    public static func prepare(for bundleIdentifier: String, store: SettingsStore = SettingsStore()) throws -> Bool {
        let snapshot = (NSScreen.main ?? NSScreen.screens.first).flatMap {
            Snapshot(size: $0.frame.size, scale: $0.backingScaleFactor, safeAreaTop: $0.safeAreaInsets.top)
        }
        return try prepare(for: bundleIdentifier, snapshot: snapshot, store: store)
    }

    @discardableResult
    static func prepare(for bundleIdentifier: String, snapshot: Snapshot?, store: SettingsStore) throws -> Bool {
        let loaded = store.load(bundleIdentifier: bundleIdentifier)
        if let problem = loaded.problem { throw problem }
        guard ResolutionMode(setting: loaded.settings.resolution) == .display, let snapshot else { return false }
        let file = store.paths.settingsFile(for: bundleIdentifier)
        let original = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
        let tree = try original.map {
            try PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] ?? [:]
        } ?? [:]
        var edited = tree
        edited["windowWidth"] = snapshot.width
        edited["windowHeight"] = snapshot.height
        edited["customScaler"] = snapshot.scale
        guard edited as NSDictionary != tree as NSDictionary else { return false }
        // A raw delta preserves controls, unknown keys and every other performance preference.
        let data = try PropertyListSerialization.data(fromPropertyList: edited, format: .xml, options: 0)
        _ = try store.saveLegacy(data, basedOn: original, bundleIdentifier: bundleIdentifier)
        return true
    }
}
#endif
