import Foundation

/// Counts the game's frame starts (the engine's frame-start callback), so input can wait for the
/// game to have run its update instead of a fixed wall-clock delay.
@MainActor
final class FrameTicker {
    static let shared = FrameTicker()

    private(set) var count: UInt64 = 0
    private var waiters: [UInt64: (target: UInt64, continuation: CheckedContinuation<Void, Never>, timeout: Task<Void, Never>)] = [:]
    private var nextWaiter: UInt64 = 0
    /// Inputs waiting for frames (diagnostics and tests).
    var pendingWaiters: Int { waiters.count }

    /// One frame started.
    func tick() {
        count &+= 1
        for (id, waiter) in waiters where waiter.target <= count {
            finish(id)
        }
    }

    /// Returns after `frames` more frame starts, or after `timeout` when the game draws no frames
    /// (a loading screen, or an engine without the callback), whichever comes first.
    func wait(frames: UInt64, timeout: Duration) async {
        guard frames > 0, !Task.isCancelled else { return }
        nextWaiter &+= 1
        let id = nextWaiter
        let target = count &+ frames
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                guard !Task.isCancelled else { continuation.resume(); return }
                let timer = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finish(id)
                }
                waiters[id] = (target, continuation, timer)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id) }
        }
    }

    private func finish(_ id: UInt64) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume()
    }
}
