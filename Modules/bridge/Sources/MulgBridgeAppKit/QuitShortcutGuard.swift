import Foundation

/// The ⌘Q decision for game windows: a first press warns, a second press within `window` quits.
/// Key repeats from a held ⌘Q never quit on their own.
struct QuitShortcutGuard: Sendable {
    enum Outcome: Equatable { case warn, quit, ignore }

    /// Seconds a second press has to arrive in.
    static let window: TimeInterval = 2

    private var armedAt: TimeInterval?

    mutating func press(at time: TimeInterval, isRepeat: Bool) -> Outcome {
        if isRepeat { return .ignore }
        if let armedAt, time >= armedAt, time - armedAt <= Self.window {
            self.armedAt = nil
            return .quit
        }
        armedAt = time
        return .warn
    }
}
