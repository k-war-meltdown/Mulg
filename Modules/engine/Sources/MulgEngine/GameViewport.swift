import Foundation
import QuartzCore
import MulgEngineHooks

enum ViewportGeometry {
    static func visibleRect(of layer: CALayer, in window: CALayer) -> CGRect {
        // ponytail: coverage uses clipped bounding rectangles; exact polygons need a measured selection failure.
        var area = layer.convert(layer.bounds, to: window).intersection(window.bounds)
        var ancestor: CALayer? = layer
        while let current = ancestor {
            guard !current.isHidden, current.opacity > 0 else { return .null }
            if current.masksToBounds { area = area.intersection(current.convert(current.bounds, to: window)) }
            if let mask = current.mask { area = area.intersection(current.convert(mask.frame, to: window)) }
            if current === window { return area }
            ancestor = current.superlayer
        }
        return .null
    }

    static func contains(_ point: CGPoint, layer: CALayer, window: CALayer) -> Bool {
        guard window.bounds.contains(point) else { return false }
        var ancestor: CALayer? = layer
        while let current = ancestor {
            let local = current.convert(point, from: window)
            guard !current.isHidden, current.opacity > 0,
                  (current !== layer || current.bounds.contains(local)),
                  (!current.masksToBounds || current.bounds.contains(local)),
                  (current.mask.map { $0.frame.contains(local) } ?? true) else { return false }
            if current === window { return true }
            ancestor = current.superlayer
        }
        return false
    }
}

enum ViewportSelection {
    // A small coverage difference never rebuilds the render path or releases held controls.
    static func keepsCurrent(coverage: Double, focused: Bool, bestCoverage: Double, bestFocused: Bool) -> Bool {
        focused == bestFocused && coverage >= bestCoverage * 0.8
    }
}
#if canImport(UIKit) && !os(watchOS)
import UIKit

/// Graphics and touches share a weakly held UIKit surface, including smaller replacement
/// views after a loading screen or scene change.
@MainActor
public final class GameViewport {
    public static let shared = GameViewport()
    private let candidates = NSMapTable<CAMetalLayer, NSNumber>.weakToStrongObjects()
    public private(set) weak var layer: CAMetalLayer?
    public private(set) weak var view: UIView?
    private var lastWindowID: ObjectIdentifier?
    private var lastScreenID: ObjectIdentifier?
    private var lastWindowBounds = CGRect.zero
    private var lastLayerBounds = CGRect.zero
    private var lastPixelSize: CGSize?
    private var lastScale: CGFloat = 0
    private var lastSafeAreaInsets = UIEdgeInsets.zero
    private var lastMapping: CGAffineTransform = .identity
    public private(set) var geometryRevision: UInt64 = 0
    public var window: UIWindow? {
        if let window = view?.window { return window }
        for scene in UIApplication.shared.connectedScenes {
            guard let scene = scene as? UIWindowScene, Self.isOnScreen(scene) else { continue }
            if let window = scene.windows.first(where: \.isKeyWindow) { return window }
        }
        return UIApplication.shared.windows.first(where: { $0.isKeyWindow && !$0.isHidden })
    }

    public func drawing(_ candidate: CAMetalLayer) -> CAMetalLayer? {
        drawing([(candidate, CACurrentMediaTime())])
    }

    /// Timestamps come from the render thread; a stalled main queue must not revive old surfaces.
    public func drawing(_ activity: [(CAMetalLayer, CFTimeInterval)]) -> CAMetalLayer? {
        let now = CACurrentMediaTime()
        for (candidate, time) in activity where time.isFinite {
            let previous = candidates.object(forKey: candidate)?.doubleValue ?? 0
            candidates.setObject(NSNumber(value: max(previous, min(time, now))), forKey: candidate)
        }
        let visible = candidates.keyEnumerator().allObjects.compactMap { object -> (layer: CAMetalLayer, view: UIView, coverage: Double, focused: Bool)? in
            guard let layer = object as? CAMetalLayer,
                  let lastDraw = candidates.object(forKey: layer), now - lastDraw.doubleValue <= 2 else { return nil }
            var ancestor: CALayer? = layer
            var owner: UIView?
            while let current = ancestor {
                guard !current.isHidden && current.opacity > 0 else { return nil }
                if owner == nil { owner = current.delegate as? UIView }
                ancestor = current.superlayer
            }
            guard let owner, let window = owner.window, !window.isHidden,
                  (window.windowScene.map { Self.isOnScreen($0) }
                    ?? (mulg_engine_effective_lifecycle_state(UIApplication.shared, NSSelectorFromString("applicationState")) != 2)),
                  owner.bounds.width > 0, owner.bounds.height > 0 else { return nil }
            let area = ViewportGeometry.visibleRect(of: layer, in: window.layer)
            guard !area.isNull, !area.isEmpty else { return nil }
            let coverage = Double(area.width * area.height / max(1, window.bounds.width * window.bounds.height))
            return (layer, owner, coverage, window.isKeyWindow)
        }
        guard var selected = visible.max(by: {
            $0.focused == $1.focused ? $0.coverage < $1.coverage : !$0.focused && $1.focused
        }) else {
            let changed = view != nil
            layer = nil; view = nil
            if changed { NotificationCenter.default.post(name: Self.changed, object: nil) }
            refreshGeometry()
            return nil
        }
        if let current = visible.first(where: { $0.layer === layer }),
           ViewportSelection.keepsCurrent(coverage: current.coverage, focused: current.focused,
                                          bestCoverage: selected.coverage, bestFocused: selected.focused) {
            selected = current
        }
        let changed = view !== selected.view || layer !== selected.layer
        layer = selected.layer
        view = selected.view
        if changed { NotificationCenter.default.post(name: Self.changed, object: nil) }
        refreshGeometry()
        return selected.layer
    }

    /// Foreground, active or not. Only foreground-active scenes used to count, so clicking another app (the game
    /// inactive but on screen) emptied the viewport within half a second: graphics then reset the render size
    /// to the game's own and switched MetalFX off, and restored both on return, reallocating every time.
    static func isOnScreen(_ scene: UIWindowScene) -> Bool {
        (0...1).contains(mulg_engine_effective_lifecycle_state(scene, NSSelectorFromString("activationState")))
    }

    public static let changed = Notification.Name("MulgGameViewportChanged")
    public static let geometryChanged = Notification.Name("MulgGameViewportGeometryChanged")
    public func laidOut(_ laidOut: UIView) {
        if laidOut === window || view?.isDescendant(of: laidOut) == true { refreshGeometry() }
    }
    private func refreshGeometry() {
        let window = window
        let windowID = window.map(ObjectIdentifier.init), screenID = window.map { ObjectIdentifier($0.screen) }
        let windowBounds = window?.bounds ?? .zero, layerBounds = layer?.bounds ?? view?.bounds ?? windowBounds
        let scale = window?.screen.nativeScale ?? 0
        let safeAreaInsets = view?.safeAreaInsets ?? window?.safeAreaInsets ?? .zero
        let pixels = pixelSize
        let mapping = captureSurface()?.transform ?? .identity
        guard windowID != lastWindowID || screenID != lastScreenID || windowBounds != lastWindowBounds
            || layerBounds != lastLayerBounds || scale != lastScale || mapping != lastMapping
            || pixels != lastPixelSize || safeAreaInsets != lastSafeAreaInsets else { return }
        lastWindowID = windowID; lastScreenID = screenID
        lastWindowBounds = windowBounds; lastLayerBounds = layerBounds; lastScale = scale
        lastMapping = mapping
        lastSafeAreaInsets = safeAreaInsets
        lastPixelSize = pixels
        geometryRevision &+= 1
        NotificationCenter.default.post(name: Self.geometryChanged, object: window)
    }
    public var bounds: CGRect { CGRect(origin: .zero, size: layer?.bounds.size ?? view?.bounds.size ?? window?.bounds.size ?? .zero) }
    /// Engine callers see the real output drawable, not the game's hidden MetalFX source.
    public var pixelSize: CGSize? {
        guard let pixels = layer?.drawableSize, pixels.width.isFinite, pixels.height.isFinite,
              pixels.width > 0, pixels.height > 0 else { return nil }
        return pixels
    }

    /// Held touches keep their original surface/window until release, even after selection changes.
    @MainActor public struct Surface {
        public let window: UIWindow
        private let layer: CALayer
        public let bounds: CGRect
        public let transform: CGAffineTransform
        private let windowBounds: CGRect
        fileprivate init(window: UIWindow, layer: CALayer) {
            self.window = window
            self.layer = layer
            bounds = layer.bounds
            windowBounds = window.bounds
            transform = Self.mapping(layer, window)
        }
        private static func mapping(_ layer: CALayer, _ window: UIWindow) -> CGAffineTransform {
            let origin = layer.convert(layer.bounds.origin, to: window.layer)
            let x = layer.convert(CGPoint(x: layer.bounds.minX + 1, y: layer.bounds.minY), to: window.layer)
            let y = layer.convert(CGPoint(x: layer.bounds.minX, y: layer.bounds.minY + 1), to: window.layer)
            return CGAffineTransform(a: x.x - origin.x, b: x.y - origin.y,
                c: y.x - origin.x, d: y.y - origin.y, tx: origin.x, ty: origin.y)
        }
        public var isValid: Bool {
            return bounds.width > 0 && bounds.height > 0
                && transform.a.isFinite && transform.b.isFinite
                && transform.c.isFinite && transform.d.isFinite
                && transform.tx.isFinite && transform.ty.isFinite
                && abs(transform.a * transform.d - transform.b * transform.c) > 0.000001
        }
        /// A gesture never inherits a new scale, rotation or translation halfway through.
        public var geometryIsCurrent: Bool {
            guard !window.isHidden, layer.bounds == bounds, window.bounds == windowBounds else { return false }
            var ancestor: CALayer? = layer
            while let current = ancestor {
                // A hidden render view can remain attached at exactly the same
                // coordinates behind a menu or replacement scene.
                guard !current.isHidden, current.opacity > 0 else { return false }
                if current === window.layer {
                    let current = Self.mapping(layer, window)
                    return abs(transform.a - current.a) < 0.0001
                        && abs(transform.b - current.b) < 0.0001
                        && abs(transform.c - current.c) < 0.0001
                        && abs(transform.d - current.d) < 0.0001
                        && abs(transform.tx - current.tx) < 0.0001
                        && abs(transform.ty - current.ty) < 0.0001
                }
                ancestor = current.superlayer
            }
            return false
        }
        public func windowPoint(_ point: CGPoint) -> CGPoint {
            point.applying(transform)
        }
        public func localPoint(_ point: CGPoint) -> CGPoint {
            point.applying(transform.inverted())
        }
    }
    public func captureSurface(in fallback: UIWindow? = nil) -> Surface? {
        guard let window = window ?? fallback else { return nil }
        return Surface(window: window, layer: layer ?? view?.layer ?? window.layer)
    }
    public func windowPoint(_ point: CGPoint) -> CGPoint {
        captureSurface()?.windowPoint(point) ?? point
    }
    public func viewPoint(_ point: CGPoint) -> CGPoint? {
        guard let window, let layer = layer ?? view?.layer, let surface = captureSurface(), surface.isValid else { return nil }
        return ViewportGeometry.contains(point, layer: layer, window: window.layer)
            ? surface.localPoint(point) : nil
    }
}
#endif
