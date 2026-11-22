import CoreGraphics
import Foundation

/// Digital movement has one coordinate system: right is +X, forward/up is +Y.
/// It knows nothing about pixels, window shapes, mouse movement or camera heading.
public struct DigitalJoystick: Sendable, Equatable {
    public enum Direction: Int, Sendable, CaseIterable {
        case up, down, left, right
    }

    private var held: Set<Direction> = []

    public init() {}

    public func isHeld(_ direction: Direction) -> Bool { held.contains(direction) }

    /// Repeats are idempotent; opposing inputs cancel, regardless of press order.
    public mutating func set(_ direction: Direction, pressed: Bool) {
        if pressed { held.insert(direction) }
        else { held.remove(direction) }
    }

    public mutating func reset() { held.removeAll(keepingCapacity: true) }

    /// A single axis is EXACTLY zero when that axis has no net input. Diagonals only
    /// exist while both axes are active, and have the same magnitude as cardinals.
    public func vector(magnitude: CGFloat = 1) -> CGVector {
        let x: CGFloat = (isHeld(.right) ? 1 : 0) - (isHeld(.left) ? 1 : 0)
        let y: CGFloat = (isHeld(.up) ? 1 : 0) - (isHeld(.down) ? 1 : 0)
        let scale = magnitude.isFinite ? min(1, max(0, magnitude)) : 0
        let divisor: CGFloat = x != 0 && y != 0 ? sqrt(2) : 1
        return CGVector(dx: x / divisor * scale, dy: y / divisor * scale)
    }
}
