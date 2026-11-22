import Foundation
import CoreFoundation
import MulgContracts
import Synchronization

/// Writes the small JSON reports the Mulg app reads (diagnostics folder) on one utility queue,
/// so file I/O never runs on the game's main thread. Writes to one file coalesce: only the
/// newest content is written, and content equal to the file's last write is skipped while the
/// file is still there.
nonisolated public final class ReportWriter: Sendable {
    public static let shared = ReportWriter()

    private enum Pending: Sendable {
        case bytes(Data)
        case encode(@Sendable () throws -> Data)

        func data() throws -> Data {
            switch self {
            case .bytes(let bytes): bytes
            case .encode(let encode): try encode()
            }
        }
    }

    private struct State {
        var pending: [URL: Pending] = [:]
        var written: [URL: Data] = [:]
        var draining = false
    }
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "io.mulg.reports", qos: .utility)

    public init() {}

    /// Queues `data` for `file`, creating its folder when needed. Returns at once.
    public func write(_ data: Data, to file: URL) {
        enqueue(.bytes(data), to: file)
    }

    private func enqueue(_ pending: Pending, to file: URL) {
        let (start, replaced) = state.withLock { state -> (Bool, Pending?) in
            let replaced = state.pending.updateValue(pending, forKey: file)
            let start = !state.draining
            state.draining = true
            return (start, replaced)
        }
        // Releasing a coalesced snapshot may destroy a large captured value.
        // Keep that cleanup outside the mutex and schedule the drain first.
        withExtendedLifetime(replaced) {
            if start { queue.async { self.drain() } }
        }
    }

    /// Copy a Sendable snapshot now, but encode/sort it on the writer queue. Pending
    /// snapshots coalesce by file before encoding, just like already-encoded reports.
    public func writeSnapshot(_ value: some Encodable & Sendable, to file: URL, dateAsISO8601: Bool = false) {
        enqueue(.encode {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if dateAsISO8601 { encoder.dateEncodingStrategy = .iso8601 }
            return try encoder.encode(value)
        }, to: file)
    }

    /// The ordinary JSONEncoder format, encoded only after pending snapshots have
    /// coalesced. Keeps compact report formats without encoding on the game thread.
    public func writeCompactSnapshot(_ value: some Encodable & Sendable, to file: URL) {
        enqueue(.encode { try JSONEncoder().encode(value) }, to: file)
    }

    /// Freeze Foundation dictionaries into value-only data. No mutable Foundation
    /// object or module/UI reference is carried to the background queue.
    public func writeJSONObject(_ report: [String: Any], to file: URL) {
        guard let snapshot = JSONValue(report) else { return }
        writeSnapshot(snapshot, to: file)
    }

    /// Encodes on the caller (values need not be Sendable) and queues the result.
    public func write(_ value: some Encodable, to file: URL, encoder: JSONEncoder = JSONEncoder()) {
        do {
            write(try encoder.encode(value), to: file)
        } catch {
            MulgLog.logger(.engine).error("Could not encode \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Waits until every queued write has finished.
    public func flush() {
        queue.sync {}
    }

    private func drain() {
        while let (file, pending, last) = state.withLock({ state -> (URL, Pending, Data?)? in
            guard let file = state.pending.keys.first, let data = state.pending.removeValue(forKey: file) else {
                state.draining = false
                return nil
            }
            return (file, data, state.written[file])
        }) {
            // Reports can keep arriving before this drain returns. Bound temporary
            // Foundation objects to one item rather than the entire backlog.
            autoreleasepool {
                do {
                    let data = try pending.data()
                    if data == last, FileManager.default.fileExists(atPath: file.path) {
                        return // Skip this item; the outer drain continues.
                    }
                    do {
                        try data.writeBeside(to: file)
                    } catch {
                        // The folder may be new, or removed while the game runs.
                        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.writeBeside(to: file)
                    }
                    state.withLock { $0.written[file] = data }
                } catch {
                    MulgLog.logger(.engine).error("Could not write \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}

/// Preserves JSON scalar types, including integer counters beyond Double's exact range.
private indirect enum JSONValue: Encodable, Sendable {
    case string(String), signed(Int64), unsigned(UInt64), number(Double), bool(Bool)
    case object([String: Self]), array([Self]), null

    init?(_ value: Any) {
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() { self = .bool(value.boolValue) }
            else {
                switch UnicodeScalar(UInt8(bitPattern: value.objCType[0])) {
                case "c", "s", "i", "l", "q": self = .signed(value.int64Value)
                case "C", "S", "I", "L", "Q": self = .unsigned(value.uint64Value)
                default:
                    guard value.doubleValue.isFinite else { return nil }
                    self = .number(value.doubleValue)
                }
            }
        } else if let value = value as? String { self = .string(value) }
        else if let value = value as? [String: Any] {
            var result: [String: Self] = [:]
            result.reserveCapacity(value.count)
            for (key, value) in value { guard let value = Self(value) else { return nil }; result[key] = value }
            self = .object(result)
        } else if let value = value as? [Any] {
            var result: [Self] = []
            result.reserveCapacity(value.count)
            for value in value { guard let value = Self(value) else { return nil }; result.append(value) }
            self = .array(result)
        } else if value is NSNull { self = .null }
        else { return nil }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .signed(let value): try container.encode(value)
        case .unsigned(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
