import Foundation

extension KeyedDecodingContainer {
    /// Decodes `key` if it is present, otherwise returns `fallback`.
    ///
    /// Settings files are written by several app versions (upstream Mulg 2.x/3.x and
    /// this fork), so every field must tolerate being missing.
    func value<T: Decodable>(_ key: Key, default fallback: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback()
    }
}
