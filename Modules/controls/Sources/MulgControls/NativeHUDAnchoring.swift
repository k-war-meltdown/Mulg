#if canImport(UIKit) && !os(watchOS)
import CoreGraphics
import MulgContracts
import MulgEngine
import UIKit

/// Native UIKit buttons already expose their actual hitboxes; these need no screenshots.
/// Weak associations follow the same live control across resize without searching a new UI.
@MainActor
final class NativeHUDAnchoring {
    private final class Reference {
        weak var control: UIControl?
        let signature: String
        init(_ control: UIControl, signature: String) { self.control = control; self.signature = signature }
    }
    private var references: [ControlBindingAddress: Reference] = [:]

    func reset() { references.removeAll() }

    func positions(for targets: [HUDControlTarget]) -> [ControlBindingAddress: CGPoint] {
        let viewport = GameViewport.shared
        guard let window = viewport.window, viewport.bounds.width > 0, viewport.bounds.height > 0 else { return [:] }
        var positions: [ControlBindingAddress: CGPoint] = [:]
        for target in targets where target.address.kind == .button || target.address.kind == .draggable {
            let size = viewport.bounds.size
            let expected = CGPoint(x: target.transform.xCoord * size.width, y: target.transform.yCoord * size.height)
            var control = references[target.address].flatMap {
                $0.signature == target.bindingSignature ? $0.control : nil
            }
            let reused = control != nil
            if control == nil {
                references[target.address] = nil
                var hit = window.hitTest(viewport.windowPoint(expected), with: nil)
                while let view = hit {
                    if let candidate = view as? UIControl, !(candidate is UITextField), !(candidate is UISlider) {
                        control = candidate; break
                    }
                    hit = view.superview
                }
            }
            guard let control, control.window === window, control.isEnabled,
                  !control.isHidden, control.alpha > 0.5, control.isUserInteractionEnabled else {
                references[target.address] = nil; continue
            }
            let frame = control.convert(control.bounds, to: window)
            guard let start = viewport.viewPoint(frame.origin),
                  let end = viewport.viewPoint(CGPoint(x: frame.maxX, y: frame.maxY)) else { continue }
            let rect = CGRect(x: start.x, y: start.y, width: end.x - start.x, height: end.y - start.y)
            guard rect.width > 3, rect.height > 3, rect.width < size.height * 0.25,
                  rect.height < size.height * 0.2, viewport.bounds.contains(rect),
                  reused || (rect.contains(expected)
                    && hypot(rect.midX - expected.x, rect.midY - expected.y) < size.height * 0.045) else { continue }
            // Invisible ancestors and offscreen/remapped hitboxes are never accepted.
            var ancestor: UIView? = control
            var visible = true
            while let current = ancestor {
                if current.isHidden || current.alpha <= 0.5 { visible = false; break }
                if current === window { break }
                ancestor = current.superview
            }
            guard visible, window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil).map({
                $0 === control || $0.isDescendant(of: control)
            }) == true else { continue }
            references[target.address] = Reference(control, signature: target.bindingSignature)
            positions[target.address] = CGPoint(x: rect.midX / size.width, y: rect.midY / size.height)
        }
        return positions
    }
}
#endif
