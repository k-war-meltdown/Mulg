import CoreGraphics
import Foundation
import MulgContracts

/// Trackpad pinch and rotate as two-finger touch gestures (PLAN.md §13.2), for maps, strategy
/// and puzzle games that need multi-touch a mouse can't give.
@MainActor
public final class TrackpadGestures {
    private let injector: any TouchInjecting
    private let metrics: () -> ScreenMetrics
    private var first: Int?
    private var second: Int?
    private var center: CGPoint = .zero
    private var radius: CGFloat = 0
    private var angle: CGFloat = 0
    private enum Gesture: Hashable { case magnify, rotate }
    private var activeGestures: Set<Gesture> = []

    /// Starting distance of each finger from the centre, as a fraction of the screen height.
    static let startRadiusFraction: CGFloat = 0.12

    public init(injector: any TouchInjecting, metrics: @escaping () -> ScreenMetrics) {
        self.injector = injector
        self.metrics = metrics
    }

    /// Phase codes from the bridge: 1 began, 2 changed, 3 ended, 4 cancelled.
    public func magnify(by amount: CGFloat, phase: Int, at point: CGPoint?) {
        if phase == 4 { cancel(); return }
        if phase == 1 { begin(.magnify, at: point) }
        if amount.isFinite, amount != 0, isActive {
            radius = max(8, radius * (1 + amount))
            moveFingers()
        }
        if phase == 3 { finish(.magnify) }
    }

    /// Rotation in degrees (counter-clockwise positive, like AppKit).
    public func rotate(by degrees: CGFloat, phase: Int, at point: CGPoint?) {
        if phase == 4 { cancel(); return }
        if phase == 1 { begin(.rotate, at: point) }
        if degrees.isFinite, degrees != 0, isActive {
            // Screen y grows downwards, so counter-clockwise on screen is a negative angle.
            angle -= degrees * .pi / 180
            moveFingers()
        }
        if phase == 3 { finish(.rotate) }
    }

    private func begin(_ gesture: Gesture, at point: CGPoint?) {
        if activeGestures.contains(gesture) { cancel() }
        let starting = activeGestures.isEmpty
        activeGestures.insert(gesture)
        guard starting else { return }
        let screen = metrics()
        center = point ?? CGPoint(x: screen.width / 2, y: screen.height / 2)
        radius = screen.height * Self.startRadiusFraction
        angle = 0
        injector.touch(&first, at: fingerPoint(0), phase: .began)
        injector.touch(&second, at: fingerPoint(.pi), phase: .began)
        // Keep two-finger ownership atomic when UIKit refuses either contact.
        guard first != nil, second != nil else { cancel(); return }
    }

    private func moveFingers() {
        guard first != nil, second != nil else { cancel(); return }
        injector.touch(&first, at: fingerPoint(0), phase: .moved)
        guard first != nil else { cancel(); return }
        injector.touch(&second, at: fingerPoint(.pi), phase: .moved)
        if second == nil { cancel() }
    }

    private func end() {
        injector.touch(&first, at: fingerPoint(0), phase: .ended)
        injector.touch(&second, at: fingerPoint(.pi), phase: .ended)
    }

    private func finish(_ gesture: Gesture) {
        activeGestures.remove(gesture)
        if activeGestures.isEmpty { end() }
    }

    /// Focus and mode changes must lift both fingers even if AppKit sends no ended phase.
    func cancel() {
        activeGestures.removeAll()
        injector.cancel(&first, at: fingerPoint(0))
        injector.cancel(&second, at: fingerPoint(.pi))
    }

    func fingerPoint(_ offset: CGFloat) -> CGPoint {
        CGPoint(x: center.x + cos(angle + offset) * radius, y: center.y + sin(angle + offset) * radius)
    }

    public var isActive: Bool { first != nil || second != nil }
}
