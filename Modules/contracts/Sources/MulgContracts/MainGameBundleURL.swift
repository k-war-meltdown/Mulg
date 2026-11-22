import CoreFoundation
import Foundation
#if canImport(Darwin)
import Darwin
import MachO
#endif

/// NSBundle's nominally non-null bundleURL can be nil during a restricted startup.
/// Read the nullable CoreFoundation result, then fall back to the actual executable.
public enum MainGameBundleURL {
    /// A fallback path is suitable for diagnosis, but it does not repair Apple's
    /// cached main bundle. IOSurface requires the actual CF main bundle to exist.
    public static func nativeMainBundle() -> Bundle? {
        guard let native = CFBundleGetMainBundle(),
              let identifier = CFBundleGetIdentifier(native),
              let url = CFBundleCopyBundleURL(native), (url as URL).isFileURL,
              let executableBundle = executableAppURL(),
              (url as URL).resolvingSymlinksInPath().standardizedFileURL.path == executableBundle.path else { return nil }
        let bundle = Bundle.main
        guard bundle.bundleIdentifier == (identifier as String) else { return nil }
        return bundle
    }

    public static func resolve() -> URL? {
        // The executable remains authoritative if CF has cached the wrong/missing bundle.
        if let actual = executableAppURL() { return actual }
        if let bundle = CFBundleGetMainBundle(), let url = CFBundleCopyBundleURL(bundle) {
            return (url as URL).standardizedFileURL
        }
        return nil
    }

    private static func executableAppURL() -> URL? {
        #if canImport(Darwin)
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0, size <= 65_536 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0,
              let path = buffer.withUnsafeBufferPointer({ String(validatingCString: $0.baseAddress!) }),
              !path.isEmpty else { return nil }
        var folder = URL(fileURLWithPath: path).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<4 {
            if folder.pathExtension == "app" { return folder.standardizedFileURL }
            folder.deleteLastPathComponent()
        }
        #endif
        return nil
    }
}
