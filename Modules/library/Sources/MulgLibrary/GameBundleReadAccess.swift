import Foundation

/// A legacy sandbox profile must still permit reading the real app bundle on an
/// external disk. This grants no write access to the app or unrelated folders.
public enum GameBundleReadAccess {
    public static func sandboxRules(for app: URL) -> [String] {
        let canonical = app.resolvingSymlinksInPath().standardizedFileURL
        guard canonical.isFileURL, canonical.pathExtension == "app" else { return [] }
        func quote(_ path: String) -> String {
            path.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
        }
        let path = quote(canonical.path)
        return ["(allow file-read* file-map-executable (subpath \"\(path)\"))",
                "(allow file-read-metadata (path-ancestors \"\(path)\"))"]
    }
}
