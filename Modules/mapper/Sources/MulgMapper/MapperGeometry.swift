import CoreGraphics
import Foundation
import MulgKeymaps

/// Where things go on the mapper's canvas. Pure arithmetic, so it is tested without a screen.
public enum MapperGeometry {
    public enum Edge: Int, CaseIterable, Sendable { case left, right, top, bottom }
    /// Controls smaller than this on screen are drawn at this size, so a tiny button can still be clicked.
    public static let minimumControlSide: CGFloat = 40

    /// Joysticks are drawn at the finger's real reach: the runtime moves the finger at most a
    /// quarter of the stored size from the centre, so the circle's diameter is half of that size.
    /// Fit the circle over the game's stick and a full press reaches its edge.
    public static let joystickDrawScale: CGFloat = 0.5

    /// The canvas rectangle of a control: keymaps store the centre as fractions of the canvas and
    /// the size as a percentage of its longer side (`ScreenMetrics`), drawn at `drawScale` of it.
    public static func frame(of transform: KeyModelTransform, canvas: CGSize, metrics: ScreenMetrics,
                             drawScale: CGFloat = 1) -> CGRect {
        let side = metrics.size(transform.size) * drawScale
        let width = max(side * transform.effectiveWidthScale * metrics.horizontalUnitScale, minimumControlSide)
        let height = max(side * transform.effectiveHeightScale, minimumControlSide)
        return CGRect(x: transform.xCoord * canvas.width - width / 2,
                      y: transform.yCoord * canvas.height - height / 2, width: width, height: height)
    }

    /// Drag a single edge, leaving the opposite edge and the other axis fixed.
    public static func resizing(_ frame: CGRect, edge: Edge, to point: CGPoint, in canvas: CGSize) -> CGRect {
        guard point.x.isFinite, point.y.isFinite, canvas.width > 0, canvas.height > 0 else { return frame }
        var result = frame
        let minimumWidth = min(minimumControlSide, canvas.width)
        let minimumHeight = min(minimumControlSide, canvas.height)
        switch edge {
        case .left:
            let x = min(max(point.x, 0), frame.maxX - minimumWidth)
            result.origin.x = x; result.size.width = frame.maxX - x
        case .right: result.size.width = max(min(point.x, canvas.width) - frame.minX, minimumWidth)
        case .top:
            let y = min(max(point.y, 0), frame.maxY - minimumHeight)
            result.origin.y = y; result.size.height = frame.maxY - y
        case .bottom: result.size.height = max(min(point.y, canvas.height) - frame.minY, minimumHeight)
        }
        return result
    }

    /// The stored size for a resize handle dragged to `offset` from the control's centre (canvas
    /// points): the drawn shape then reaches the handle.
    public static func size(forHandleOffset offset: CGVector, metrics: ScreenMetrics, drawScale: CGFloat = 1) -> CGFloat {
        let scale = metrics.horizontalUnitScale > 0 ? metrics.horizontalUnitScale : 1
        let side = 2 * hypot(offset.dx / scale, offset.dy)
        guard metrics.percent > 0, drawScale > 0 else { return 0 }
        return side / drawScale / metrics.percent
    }

    /// A point on the canvas as fractions of it, clamped to the canvas.
    public static func relative(_ point: CGPoint, in canvas: CGSize) -> CGPoint {
        guard canvas.width > 0, canvas.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: min(max(point.x / canvas.width, 0), 1), y: min(max(point.y / canvas.height, 0), 1))
    }

    /// Where a popover of `size` opens for a click at `anchor`: centred on the click, moved inside
    /// `bounds` with `margin` to spare.
    public static func popoverFrame(size: CGSize, anchor: CGPoint, in bounds: CGRect, margin: CGFloat = 8) -> CGRect {
        let x = min(max(anchor.x - size.width / 2, bounds.minX + margin), max(bounds.maxX - size.width - margin, bounds.minX + margin))
        let y = min(max(anchor.y - size.height / 2, bounds.minY + margin), max(bounds.maxY - size.height - margin, bounds.minY + margin))
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Where the panel of the selected control goes: below it, or above when there is no room, or
    /// beside it. It stays inside `bounds`, clear of `keepClear` (the toolbar), and never covers the
    /// control itself unless the control fills the canvas.
    public static func inspectorFrame(size: CGSize, near control: CGRect, in bounds: CGRect,
                                      keepClear: CGRect = .null, gap: CGFloat = 12, margin: CGFloat = 8) -> CGRect {
        let usable = bounds.insetBy(dx: margin, dy: margin)
        func clamped(_ rect: CGRect) -> CGRect {
            var rect = rect
            rect.origin.x = min(max(rect.origin.x, usable.minX), max(usable.maxX - rect.width, usable.minX))
            rect.origin.y = min(max(rect.origin.y, usable.minY), max(usable.maxY - rect.height, usable.minY))
            return rect
        }
        let centredX = control.midX - size.width / 2
        let centredY = control.midY - size.height / 2
        let candidates = [
            CGRect(x: centredX, y: control.maxY + gap, width: size.width, height: size.height),          // below
            CGRect(x: centredX, y: control.minY - gap - size.height, width: size.width, height: size.height), // above
            CGRect(x: control.maxX + gap, y: centredY, width: size.width, height: size.height),          // right
            CGRect(x: control.minX - gap - size.width, y: centredY, width: size.width, height: size.height) // left
        ]
        for candidate in candidates {
            let fitted = clamped(candidate)
            if fitted == candidate || fitted.insetBy(dx: -0.5, dy: -0.5).contains(candidate) {
                if !fitted.intersects(control), keepClear.isNull || !fitted.intersects(keepClear) { return fitted }
            }
        }
        // Nothing fits cleanly: the first candidate that avoids the control, else the one below.
        for candidate in candidates {
            let fitted = clamped(candidate)
            if !fitted.intersects(control), keepClear.isNull || !fitted.intersects(keepClear) { return fitted }
        }
        return clamped(candidates[0])
    }
}
