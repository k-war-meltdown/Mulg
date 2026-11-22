import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Locations inside the Mulg container, shared by the app and the game runtime.
///
/// Upstream builds these by hand as `/Users/<login name>/Library/...` in four places,
/// which breaks for users whose home folder is somewhere else (PLAN.md §12 #3). Inside a
/// sandboxed game, `NSHomeDirectory()` points at the game's own container, so the real
/// home folder is read from the user database instead.
public struct ContainerPaths: Sendable, Equatable {
    public static let legacyVaultExtension = "mulgVault"
    /// Bundle ID of the Mulg app; the container is named after it (PLAN.md §0).
    public static let hostBundleIdentifier = "io.mulg.Mulg"

    /// The user's real home folder.
    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    /// Paths for the current user.
    public static func current() -> ContainerPaths {
        ContainerPaths(home: realHomeDirectory())
    }

    /// The home folder from the user database, falling back to `NSHomeDirectory()`.
    public static func realHomeDirectory() -> URL {
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        let path: String? = buffer.withUnsafeMutableBufferPointer { storage in
            guard getpwuid_r(getuid(), &entry, storage.baseAddress, storage.count, &result) == 0,
                  result != nil,
                  let directory = entry.pw_dir else {
                return nil
            }
            // Read while `storage` is still valid: pw_dir points into it.
            return String(cString: directory)
        }
        if let path, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// `~/Library/Containers/io.mulg.Mulg`
    public var mulgContainer: URL {
        home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent(Self.hostBundleIdentifier, isDirectory: true)
    }

    /// Per-game settings files.
    public var appSettingsDirectory: URL {
        mulgContainer.appendingPathComponent("App Settings", isDirectory: true)
    }

    /// Per-game keymaps.
    public var keymappingDirectory: URL {
        mulgContainer.appendingPathComponent("Keymapping", isDirectory: true)
    }

    /// MulgChain keychain databases.
    public var mulgChainDirectory: URL {
        mulgContainer.appendingPathComponent("MulgChain", isDirectory: true)
    }

    /// Installed games.
    public var applicationsDirectory: URL {
        mulgContainer.appendingPathComponent("Applications", isDirectory: true)
    }

    /// State written by this fork's runtime (safe-mode markers, diagnostics) and by the app. Each game
    /// reaches only its own files here (GameSandboxAccess); the app's own records stay out of reach.
    public var mulgStateDirectory: URL {
        mulgContainer.appendingPathComponent("Mulg", isDirectory: true)
    }

    /// One lock file per audio output device (named by a hash of its UID), shared by every game so only one
    /// running game changes a device's format at a time. The bridge builds the same path itself
    /// (AudioOutputController.lockDirectory); every game's sandbox may use this folder (GameSandboxAccess).
    public var audioOutputLockDirectory: URL {
        mulgStateDirectory.appendingPathComponent("AudioOutput", isDirectory: true)
    }

    /// Crash marker used by safe mode (PLAN.md §1.5 rule 10).
    public func safeModeMarker(for bundleIdentifier: String) -> URL {
        mulgStateDirectory
            .appendingPathComponent("SafeMode", isDirectory: true)
            .appendingPathComponent("\(bundleIdentifier).launches", isDirectory: false)
    }

    /// Per-game diagnostics: latency samples, exported reports (PLAN.md §8.3).
    public func diagnosticsDirectory(for bundleIdentifier: String) -> URL {
        mulgStateDirectory
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    /// Per-game Metal shader archives (graphics, PLAN.md §5.6). Outside the game's own container,
    /// so reinstalling or updating the game keeps them.
    public func shaderArchiveDirectory(for bundleIdentifier: String) -> URL {
        mulgStateDirectory
            .appendingPathComponent("Shaders", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    public func settingsFile(for bundleIdentifier: String) -> URL {
        appSettingsDirectory.appendingPathComponent("\(bundleIdentifier).plist", isDirectory: false)
    }

    public func keymapDirectory(for bundleIdentifier: String) -> URL {
        keymappingDirectory.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    /// `~/Library/Containers/<bundle ID>`: the game's own sandbox with its saved data.
    public func gameContainer(for bundleIdentifier: String) -> URL {
        mulgContainer.deletingLastPathComponent().appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    /// Camera reach calibration for one game (the camera module). Kept outside the game's container,
    /// so it survives reinstalling the game; the app deletes it for "Forget calibration".
    public func cameraCalibrationFile(for bundleIdentifier: String) -> URL {
        mulgStateDirectory
            .appendingPathComponent("Camera", isDirectory: true)
            .appendingPathComponent("\(bundleIdentifier).json", isDirectory: false)
    }

    public func mulgChainDatabase(for bundleIdentifier: String) -> URL {
        mulgChainDirectory.appendingPathComponent("\(bundleIdentifier).db", isDirectory: false)
    }
}
