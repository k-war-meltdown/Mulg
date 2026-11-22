import Foundation

/// Exercise the same Swift Foundation atomic-write path as SafeMode and diagnostics.
@objc(MulgStorageAtomicProbe)
final class StorageAtomicProbe: NSObject {
    @objc(writeToURL:error:)
    static func write(to url: URL) throws {
        try Data("local wrapper state".utf8).write(to: url, options: .atomic)
    }
}
