import CoreGraphics
import Foundation

/// The single resize/proportion contract. UIKit points describe the visible surface;
/// output pixels describe the game's rendering plane. MetalFX source textures never enter it.
public struct ViewportLayoutGeometry: Sendable, Equatable {
    public let points: CGSize
    public let outputPixels: CGSize
    public let revision: UInt64
    public init(points: CGSize, outputPixels: CGSize, revision: UInt64) {
        self.points = points; self.outputPixels = outputPixels; self.revision = revision
    }
    public var isValid: Bool {
        [points.width, points.height, outputPixels.width, outputPixels.height].allSatisfy { $0.isFinite && $0 > 0 }
    }
    public var pointAspect: Double { Double(points.width / max(1, points.height)) }
    public var renderAspect: Double { Double(outputPixels.width / max(1, outputPixels.height)) }
    public var rendererMatchesPoints: Bool { isValid && abs(renderAspect / pointAspect - 1) < 0.01 }
    public func proportionsChanged(from previous: ViewportLayoutGeometry?) -> Bool {
        guard isValid else { return false }
        guard let previous, previous.isValid else { return true }
        return abs(log(pointAspect / previous.pointAspect)) > 0.0001
            || abs(log(renderAspect / previous.renderAspect)) > 0.0001
    }
}
