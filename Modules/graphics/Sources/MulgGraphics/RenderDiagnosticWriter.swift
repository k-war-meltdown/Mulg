import Foundation
import CoreFoundation
import MulgContracts
import os
import Synchronization

/// Value-only snapshots: no layers, module contexts or mutable Foundation objects cross queues.
private indirect enum RenderDiagnosticValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: Self]), array([Self]), null

    init(_ value: Any) {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) }
            else { self = number.doubleValue.isFinite ? .number(number.doubleValue) : .null }
        } else if let string = value as? String { self = .string(string) }
        else if let object = value as? [String: Any] { self = .object(object.mapValues(Self.init)) }
        else if let array = value as? [Any] { self = .array(array.map(Self.init)) }
        else { self = .null }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: Self].self) { self = .object(value) }
        else { self = .array(try container.decode([Self].self)) }
    }
}

/// One writer and at most one replacement snapshot, even when storage stalls.
final class RenderDiagnosticWriter: Sendable {
    private struct Snapshot: Equatable, Sendable {
        let url: URL
        let values: [String: RenderDiagnosticValue]
    }
    private struct State: Sendable {
        var pending: Snapshot?
        var running = false
    }
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "mulg.graphics.diagnostics", qos: .utility)

    func submit(_ report: [String: Any], to url: URL) {
        let snapshot = Snapshot(url: url, values: report.mapValues(RenderDiagnosticValue.init))
        let start = state.withLock { state in
            state.pending = snapshot
            guard !state.running else { return false }
            state.running = true
            return true
        }
        if start { queue.async { self.drain() } }
    }

    // Accessed only by the serial writer queue. Timestamp is deliberately outside equality.
    private let written = Mutex<Snapshot?>(nil)
    private func drain() {
        while let snapshot = state.withLock({ state -> Snapshot? in
            let snapshot = state.pending
            state.pending = nil
            if snapshot == nil { state.running = false }
            return snapshot
        }) {
            guard written.withLock({ $0 != snapshot }) else { continue }
            var values = snapshot.values
            values["timestamp"] = .number(Date().timeIntervalSince1970)
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(values)
                try FileManager.default.createDirectory(at: snapshot.url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try data.writeBeside(to: snapshot.url)
                written.withLock { $0 = snapshot }
            } catch {
                // Do not mark a failed write as saved: the next snapshot retries it.
                MulgLog.logger(.graphics).debug("Render geometry diagnostics could not be written")
            }
        }
    }
}
