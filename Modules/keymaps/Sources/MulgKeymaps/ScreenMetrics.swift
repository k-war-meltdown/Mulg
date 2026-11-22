import CoreGraphics

/// Positions in keymaps are fractions of the screen; sizes are percentages of its longer side.
public struct ScreenMetrics: Sendable, Equatable {
    public let width: CGFloat
    public let height: CGFloat
    public let renderWidth: CGFloat
    public let renderHeight: CGFloat

    public init(bounds: CGRect, renderSize: CGSize? = nil) {
        self.init(width: bounds.width, height: bounds.height, renderSize: renderSize)
    }

    public init(width: CGFloat, height: CGFloat, renderSize: CGSize? = nil) {
        self.width = width
        self.height = height
        if let renderSize, renderSize.width.isFinite, renderSize.height.isFinite,
           renderSize.width > 0, renderSize.height > 0 {
            renderWidth = renderSize.width
            renderHeight = renderSize.height
        } else {
            renderWidth = width
            renderHeight = height
        }
    }

    public var renderAspect: Double { Double(renderWidth / max(1, renderHeight)) }
    /// Control units use the rendered plane; its X axis projects independently into window points.
    public var canvasWidth: CGFloat { CGFloat(renderAspect) * height }
    public var horizontalUnitScale: CGFloat { width / max(1, canvasWidth) }
    public var percent: CGFloat { max(canvasWidth, height) / 100 }

    public func size(_ relative: CGFloat) -> CGFloat {
        relative * percent
    }

    public func contains(_ point: CGPoint) -> Bool {
        point.x >= 0 && point.y >= 0 && point.x <= width && point.y <= height
    }
}
