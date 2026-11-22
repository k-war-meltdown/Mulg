import CoreGraphics
import Foundation
import MulgContracts

/// Zoom as a two-finger pinch, the way iOS games expect it: scroll-wheel zoom while playing, and
/// whole zoom sweeps the camera module asks for (`CameraZoomRequested`, Camera reach calibration).
///
/// The fingers sit side by side at the screen centre, clear of the HUD at the top and bottom, and
/// are always lifted: after a short pause in scrolling, and when they reach the end of their
/// travel (the next scroll then starts a new pinch). The earlier scroll zoom lifted only when the
/// fingers met, so zooming in or stopping left two touches down on the game.
@MainActor
final class PinchZoom {
    private let injector: any TouchInjecting
    private let metrics: () -> ScreenMetrics
    private var first: Int?
    private var second: Int?
    /// Distance of each finger from the centre, in points.
    private var spread: CGFloat = 0
    private var idle: Task<Void, Never>?
    private var sweep: Task<Void, Never>?
    private var sweepID: UUID?

    /// Finger distance from the centre as a fraction of the screen width: where a pinch towards
    /// the centre starts and stops, and where a spreading pinch starts and stops.
    static let wide: CGFloat = 0.32
    static let narrow: CGFloat = 0.05
    /// A pause in scrolling this long ends the pinch.
    static let idleLift: Duration = .milliseconds(180)

    init(injector: any TouchInjecting, metrics: @escaping () -> ScreenMetrics) {
        self.injector = injector
        self.metrics = metrics
    }

    var isActive: Bool { first != nil || second != nil }

    /// One scroll step, in points: positive pinches in (the camera moves away, as on iOS),
    /// negative spreads the fingers (the camera moves closer).
    func scroll(_ amount: CGFloat) {
        guard amount != 0, amount.isFinite, sweep == nil else { return }
        let width = metrics().width
        guard width > 0 else { return }
        if !isActive {
            guard begin(spread: (amount > 0 ? Self.wide : Self.narrow) * width) else { return }
        }
        spread -= amount
        let ended = spread <= Self.narrow * width || spread >= Self.wide * width
        spread = min(max(spread, Self.narrow * width), Self.wide * width)
        guard moveFingers() else { return }
        if ended { end() } else { scheduleIdleLift() }
    }

    /// Whole pinches in one direction, each from one end of the travel to the other: `outward`
    /// moves the camera away from the character. Returns when the last finger is lifted.
    func sweep(outward: Bool, gestures: Int) async {
        cancel()
        let id = UUID()
        sweepID = id
        let task = Task { @MainActor [weak self] in
            for _ in 0..<max(1, gestures) {
                guard let self, self.sweepID == id, !Task.isCancelled else { return }
                let width = self.metrics().width
                guard width > 0 else { return }
                let from = (outward ? Self.wide : Self.narrow) * width
                let to = (outward ? Self.narrow : Self.wide) * width
                guard self.begin(spread: from) else { return }
                // Enough move events over a quarter second for games to read it as a pinch.
                for step in 1...12 {
                    try? await Task.sleep(for: .milliseconds(20))
                    guard self.sweepID == id, !Task.isCancelled else { return }
                    self.spread = from + (to - from) * CGFloat(step) / 12
                    guard self.moveFingers() else { return }
                }
                self.end()
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        sweep = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if sweepID == id {
            if task.isCancelled || Task.isCancelled { cancelFingers() } else { end() }
            sweep = nil
            sweepID = nil
        }
    }

    /// Lifts both fingers (focus lost, mode change, resize).
    func cancel() {
        sweepID = nil
        sweep?.cancel()
        sweep = nil
        cancelFingers()
    }

    private func begin(spread: CGFloat) -> Bool {
        end()
        self.spread = spread
        injector.touch(&first, at: point(-1), phase: .began)
        injector.touch(&second, at: point(1), phase: .began)
        // Touch allocation can fail independently (a busy game's contact limit).
        // A pinch must never turn into a single-finger drag or tap.
        guard first != nil, second != nil else { cancelFingers(); return false }
        return true
    }

    private func moveFingers() -> Bool {
        guard first != nil, second != nil else { cancelFingers(); return false }
        injector.touch(&first, at: point(-1), phase: .moved)
        guard first != nil else { cancelFingers(); return false }
        injector.touch(&second, at: point(1), phase: .moved)
        guard second != nil else { cancelFingers(); return false }
        return true
    }

    private func end() {
        idle?.cancel()
        idle = nil
        guard isActive else { return }
        injector.touch(&first, at: point(-1), phase: .ended)
        injector.touch(&second, at: point(1), phase: .ended)
    }

    private func cancelFingers() {
        idle?.cancel()
        idle = nil
        injector.cancel(&first, at: point(-1))
        injector.cancel(&second, at: point(1))
    }

    private func scheduleIdleLift() {
        idle?.cancel()
        idle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.idleLift)
            guard !Task.isCancelled else { return }
            self?.end()
        }
    }

    /// Finger position: `side` -1 is left of the centre, 1 right.
    func point(_ side: CGFloat) -> CGPoint {
        let screen = metrics()
        return CGPoint(x: screen.width / 2 + side * spread, y: screen.height / 2)
    }
}
