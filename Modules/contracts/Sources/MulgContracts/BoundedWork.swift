import Foundation
import Synchronization

/// Bound disk rewrites and signing processes; cancellation stops admitting new work.
public enum BoundedWork {
    private final class Admission: Sendable { let failed = Mutex(false) }
    public static func run<Item: Sendable>(_ items: [Item], limit: Int = 4,
                                           operation: @escaping @Sendable (Item) async throws -> Void) async throws {
        try Task.checkCancellation()
        let admission = Admission()
        let work: @Sendable (Item) async throws -> Void = { item in
            try Task.checkCancellation()
            guard !admission.failed.withLock({ $0 }) else { return }
            do { try await operation(item) }
            catch { admission.failed.withLock { $0 = true }; throw error }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            for _ in 0..<min(items.count, max(1, limit)) {
                let item = items[next]; next += 1
                group.addTask { try await work(item) }
            }
            while try await group.next() != nil {
                try Task.checkCancellation()
                if next < items.count && !admission.failed.withLock({ $0 }) {
                    let item = items[next]; next += 1
                    group.addTask { try await work(item) }
                }
            }
        }
    }
}
