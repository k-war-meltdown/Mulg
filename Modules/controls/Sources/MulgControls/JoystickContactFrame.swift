import CoreGraphics
import Foundation
import MulgContracts

/// One immutable neutral origin and circular travel in the renderer's coordinate plane.
/// Capture on touchdown; discard on release, cancellation or viewport replacement.
/// Project X and flip Y exactly once at the touch boundary. Never clamp axes separately:
/// that would rotate a requested diagonal or slide a cardinal away from its center.
struct JoystickContactFrame: Sendable, Equatable {
    let center: CGPoint
    let radius: CGFloat
    let horizontalScale: CGFloat

    init?(center: CGPoint, requestedRadius: CGFloat, metrics: ScreenMetrics) {
        let scale = metrics.horizontalUnitScale
        guard center.x.isFinite, center.y.isFinite, requestedRadius.isFinite,
              metrics.width.isFinite, metrics.height.isFinite, scale.isFinite,
              metrics.width > 0, metrics.height > 0, scale > 0,
              metrics.contains(center), requestedRadius > 0 else { return nil }
        let clearance = min(center.x / scale, (metrics.width - center.x) / scale,
                            center.y, metrics.height - center.y)
        let travel = min(requestedRadius, max(0, clearance - 1))
        guard travel > 0 else { return nil }
        self.center = center
        radius = travel
        horizontalScale = scale
    }

    func point(for vector: CGVector) -> CGPoint {
        guard vector.dx.isFinite, vector.dy.isFinite else { return center }
        let divisor = max(1, hypot(vector.dx, vector.dy))
        // Preserve exact cardinal coordinates rather than reconstructing them with angles.
        let x = vector.dx == 0 ? center.x : center.x + vector.dx / divisor * radius * horizontalScale
        let y = vector.dy == 0 ? center.y : center.y - vector.dy / divisor * radius
        return CGPoint(x: x, y: y)
    }

    func vector(at point: CGPoint) -> CGVector {
        CGVector(dx: (point.x - center.x) / (radius * horizontalScale),
                 dy: (center.y - point.y) / radius)
    }
}
