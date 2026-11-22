#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import Foundation
import MulgContracts

/// Applies the desktop/120 FPS install defaults and migrates earlier choices once per game.
public enum DesktopGameDefaults {
    private static let migration = "gui.desktop120Defaults.v1."

    /// Write these choices explicitly, including into older files that omit defaults, while
    /// preserving every other raw value (including unknown keys and future enum values).
    private static let settingPaths = [
        "resolution", "windowWidth", "windowHeight", "customScaler",
        "mulg.display.reportProMotion", "mulg.display.uncapFrameRate", "mulg.display.frameRateCap",
        "mulg.display.frameCapBelowRefresh", "mulg.display.backgroundThrottle",
        "mulg.display.batterySaverOnBattery", "mulg.display.thermalGuard",
        "mulg.graphics.metalFX.enabled", "mulg.graphics.metalFX.automatic",
        "mulg.graphics.fullScreenPerformanceMode", "mulg.graphics.fullResolution", "mulg.graphics.forceRenderResolution"
    ]

    /// Each pass writes its paths once per game, under its own marker.
    private static let passes: [(marker: String, paths: [String])] = [
        (migration, settingPaths)
    ]

    private static func replacing(_ tree: [String: Any], path: ArraySlice<String>, value: Any) -> [String: Any] {
        guard let key = path.first else { return tree }
        var result = tree
        result[key] = path.count == 1 ? value
            : replacing(tree[key] as? [String: Any] ?? [:], path: path.dropFirst(), value: value)
        return result
    }

    public static func apply(to settings: inout GameSettings) {
        let desktop: (width: Int, height: Int, scale: Double)? = {
            func capture() -> (width: Int, height: Int, scale: Double)? {
                guard let screen = NSScreen.main else { return nil }
                let width = Int(screen.frame.width)
                let height = ResolutionCalculator.heightAvoidingNotch(width: width,
                    height: Int(screen.frame.height), hasNotch: screen.safeAreaInsets.top > 0)
                return (width, height, screen.backingScaleFactor)
            }
            // The install callback runs off the main thread; keep AppKit access on main.
            return Thread.isMainThread ? capture() : DispatchQueue.main.sync { capture() }
        }()
        DesktopPerformanceDefaults.apply(to: &settings, desktop: desktop)
    }

    /// Mark each successful settings write separately, so a failed migration retries without
    /// overwriting later user choices in games that already migrated. Unrelated settings survive.
    @discardableResult
    public static func migrate(paths: ContainerPaths = .current(), defaults: UserDefaults = .standard) throws -> [String] {
        let files = FileManager.default
        let store = SettingsStore(paths: paths)
        var identifiers: Set<String> = []
        for (folder, suffix) in [(paths.appSettingsDirectory, ".plist"), (paths.applicationsDirectory, ".app")] {
            guard files.fileExists(atPath: folder.path) else { continue }
            for file in try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                where file.lastPathComponent.hasSuffix(suffix) {
                let identifier = String(file.lastPathComponent.dropLast(suffix.count))
                if GameSessionLease.isValidBundleIdentifier(identifier) { identifiers.insert(identifier) }
            }
        }
        if !defaults.bool(forKey: migration + "profileReset") {
            defaults.removeObject(forKey: "gui.defaultProfile")
            defaults.set(true, forKey: migration + "profileReset")
        }
        var migrated: [String] = []
        var firstFailure: Error?
        for (marker, settingPaths) in passes {
            for identifier in identifiers.sorted() where !defaults.bool(forKey: marker + identifier) {
                do {
                    let loaded = store.load(bundleIdentifier: identifier)
                    if let problem = loaded.problem { throw problem }
                    var settings = loaded.settings
                    apply(to: &settings)
                    let file = paths.settingsFile(for: identifier)
                    let original = files.fileExists(atPath: file.path) ? try Data(contentsOf: file)
                        : try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .xml, options: 0)
                    let tree = try PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any] ?? [:]
                    let desired = try PropertyListSerialization.propertyList(from: SettingsStore.encode(settings), format: nil) as! [String: Any]
                    var edited = tree
                    for key in settingPaths {
                        let path = key.split(separator: ".").map(String.init)
                        var value: Any = desired
                        for component in path { value = (value as! [String: Any])[component]! }
                        edited = replacing(edited, path: path[...], value: value)
                    }
                    if edited as NSDictionary != tree as NSDictionary {
                        let data = try PropertyListSerialization.data(fromPropertyList: edited, format: .xml, options: 0)
                        _ = try store.saveLegacy(data, basedOn: original, bundleIdentifier: identifier)
                    }
                    defaults.set(true, forKey: marker + identifier)
                    if !migrated.contains(identifier) { migrated.append(identifier) }
                } catch {
                    if firstFailure == nil { firstFailure = error }
                }
            }
        }
        if let firstFailure { throw firstFailure }
        return migrated
    }
}
#endif