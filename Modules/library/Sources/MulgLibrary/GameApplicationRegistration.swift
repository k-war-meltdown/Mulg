#if os(macOS) && !targetEnvironment(macCatalyst)
import CoreServices
import Foundation

/// Launch Services and UIKit must identify the same signed bundle, including games
/// reached through Mulg's library links or Finder shortcuts on another volume.
public enum GameApplicationRegistration {
    public struct Failure: LocalizedError, Sendable {
        public let errorDescription: String?
        fileprivate init(_ message: String) { errorDescription = message }
    }

    @discardableResult
    public static func register(_ app: URL, bundleIdentifier: String, validatingCode: Bool = false) throws -> URL {
        let canonical = app.resolvingSymlinksInPath().standardizedFileURL
        guard canonical.isFileURL,
              (try? canonical.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let data = try? Data(contentsOf: canonical.appendingPathComponent("Info.plist")),
              let metadata = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let actualIdentifier = metadata["CFBundleIdentifier"] as? String else {
            throw Failure("The installed game bundle is missing or unreadable at \(canonical.path). Check that its drive is connected.")
        }
        guard !bundleIdentifier.isEmpty, actualIdentifier == bundleIdentifier else {
            throw Failure("The installed bundle identifies as \(actualIdentifier), but the selected game is \(bundleIdentifier). Refresh the library or reinstall the selected IPA.")
        }
        guard let name = metadata["CFBundleExecutable"] as? String, !name.isEmpty,
              name != ".", name != "..", name == (name as NSString).lastPathComponent else {
            throw Failure("The installed game has no valid executable at \(canonical.path). Reinstall its IPA.")
        }
        let executable = canonical.appendingPathComponent(name).resolvingSymlinksInPath()
        guard executable.path.hasPrefix(canonical.path + "/"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw Failure("The game's executable is missing or points outside its installed bundle at \(canonical.path). Reinstall its IPA.")
        }
        // Startup checks only signed code, not gigabytes of downloaded resources.
        if validatingCode {
            do { try BundleTransaction.verifyCode(canonical) }
            catch { throw Failure("The installed game's signed code is invalid: \(error). Reinstall its IPA.") }
        }
        let status = LSRegisterURL(canonical as CFURL, true)
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "macOS could not register the installed game at \(canonical.path) (\(status))."
            ])
        }
        return canonical
    }

    /// Retire only a caller-confirmed, generated shadow bundle. This never unregisters
    /// the installed game or resets the user's Launch Services database.
    public static func unregisterShadow(_ shadow: URL) throws {
        try Command.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                        ["-u", shadow.resolvingSymlinksInPath().path])
    }
}
#endif
