import Foundation

/// A dedicated queue keeps the deadline independent of blocked game/main-actor callbacks.
/// Native termination ends the process; a returned/deferred terminate call is not completion.
final class ShutdownWatchdog {
    private let timer: any DispatchSourceTimer

    init(deadline: Double, onDeadline: @escaping @Sendable () -> Void) {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "io.mulg.shutdown"))
        timer.schedule(deadline: .now() + max(0, deadline))
        timer.setEventHandler(handler: onDeadline)
        timer.resume()
    }

    func cancel() { timer.cancel() }
    deinit { timer.cancel() }
}
