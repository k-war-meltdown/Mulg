#if canImport(UIKit) && !os(watchOS)
import MulgContracts
import MulgKeymaps
import UIKit

/// One control drawn on the canvas: a joystick ring with its four keys, a skill circle with its key,
/// a camera area or a drag area. Click it to select, drag it to move it.
final class MapperControlView: UIView {
    let id: Int
    var onTap: ((KeymapEditorModel.Part?) -> Void)?
    var onMoveBegan: (() -> Void)?
    var onMove: ((CGPoint) -> Void)?
    var onMoveEnded: (() -> Void)?
    /// The resize handle was dragged to this offset from the control's centre (canvas points).
    var onResize: ((CGVector) -> Void)?
    var onResizeEnded: (() -> Void)?
    var onBoundsResize: ((CGRect) -> Void)?
    /// A scroll notch over the control: true for larger.
    var onScrollResize: ((Bool) -> Void)?
    /// On the right edge of the selected control; drag it to resize.
    private let handle = UIView()
    private var edgeHandles: [MapperGeometry.Edge: UIView] = [:]
    private var resizeOrigin: CGRect?
    private let touchPoint = CAShapeLayer()
    private var scrolled: CGFloat = 0

    private let shape = CAShapeLayer()
    private let innerRing = CAShapeLayer()
    private let keyLabel = MapperStyle.makeLabel(size: 18, weight: .bold, alignment: .center)
    private let caption = MapperStyle.makeLabel(size: 10, weight: .semibold, color: UIColor.white.withAlphaComponent(0.85),
                                                alignment: .center)
    private let badge = MapperStyle.makeLabel(size: 12, weight: .heavy, alignment: .center)
    private var chips: [KeymapEditorModel.Part: UILabel] = [:]
    private var awaiting = false

    init(id: Int) {
        self.id = id
        super.init(frame: .zero)
        clipsToBounds = false
        layer.addSublayer(shape)
        layer.addSublayer(innerRing)
        layer.addSublayer(touchPoint)
        keyLabel.adjustsFontSizeToFitWidth = true
        keyLabel.minimumScaleFactor = 0.4
        caption.adjustsFontSizeToFitWidth = true
        caption.minimumScaleFactor = 0.5
        badge.text = "!"
        badge.backgroundColor = MapperStyle.conflict
        badge.layer.cornerRadius = 9
        badge.clipsToBounds = true
        badge.isHidden = true
        addSubview(keyLabel)
        addSubview(caption)
        addSubview(badge)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        handle.bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
        handle.layer.cornerRadius = 8
        handle.backgroundColor = MapperStyle.selection
        handle.layer.borderColor = UIColor.black.withAlphaComponent(0.6).cgColor
        handle.layer.borderWidth = 1.5
        handle.isHidden = true
        handle.isAccessibilityElement = true
        handle.accessibilityLabel = "Resize"
        let resize = UIPanGestureRecognizer(target: self, action: #selector(resized(_:)))
        resize.maximumNumberOfTouches = 1
        handle.addGestureRecognizer(resize)
        addSubview(handle)
        pan.require(toFail: resize)
        for edge in MapperGeometry.Edge.allCases {
            let grip = UIView()
            grip.bounds = CGRect(x: 0, y: 0, width: 20, height: 20)
            grip.backgroundColor = MapperStyle.selection
            grip.layer.cornerRadius = 4
            grip.layer.borderWidth = 1.5
            grip.layer.borderColor = UIColor.black.withAlphaComponent(0.6).cgColor
            grip.tag = edge.rawValue
            grip.isHidden = true
            grip.isAccessibilityElement = true
            grip.accessibilityLabel = "Resize \(edge) edge"
            let gesture = UIPanGestureRecognizer(target: self, action: #selector(resizedEdge(_:)))
            gesture.maximumNumberOfTouches = 1
            grip.addGestureRecognizer(gesture)
            pan.require(toFail: gesture)
            addSubview(grip)
            edgeHandles[edge] = grip
        }
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolledWheel(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = [] // the wheel and trackpad scrolling only, never a drag
        addGestureRecognizer(scroll)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Showing an element

    func show(_ element: KeymapEditorModel.Element, tool: MapperTool, selected: Bool, awaiting: Bool, conflict: Bool,
              selectedPart: KeymapEditorModel.Part?, frame newFrame: CGRect) {
        self.awaiting = awaiting
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = newFrame
        let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let rectangular = tool == .skill || tool == .drag || tool == .camera
        let path = rectangular
            ? UIBezierPath(roundedRect: rect, cornerRadius: min(min(rect.width, rect.height) * 0.1, 8))
            : UIBezierPath(ovalIn: rect)
        shape.path = path.cgPath
        shape.frame = bounds
        let base = MapperStyle.color(for: tool)
        shape.fillColor = base.withAlphaComponent(tool == .skill ? 0.6 : 0.34).cgColor
        shape.strokeColor = (conflict ? MapperStyle.conflict : selected ? MapperStyle.selection : UIColor.white.withAlphaComponent(0.92)).cgColor
        shape.lineWidth = selected || conflict ? 3.5 : 2
        shape.lineDashPattern = awaiting || tool == .camera ? [7, 5] : nil
        shape.shadowColor = (selected ? MapperStyle.selection : UIColor.black).cgColor
        shape.shadowOpacity = selected ? 0.9 : 0.35
        shape.shadowRadius = selected ? 9 : 4
        shape.shadowOffset = .zero
        innerRing.frame = bounds
        touchPoint.frame = bounds
        touchPoint.isHidden = !rectangular || !selected
        let cross = UIBezierPath()
        cross.move(to: CGPoint(x: bounds.midX - 5, y: bounds.midY))
        cross.addLine(to: CGPoint(x: bounds.midX + 5, y: bounds.midY))
        cross.move(to: CGPoint(x: bounds.midX, y: bounds.midY - 5))
        cross.addLine(to: CGPoint(x: bounds.midX, y: bounds.midY + 5))
        touchPoint.path = cross.cgPath
        touchPoint.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        touchPoint.lineWidth = 1
        if tool == .joystick || tool == .floatingJoystick {
            innerRing.path = UIBezierPath(ovalIn: bounds.insetBy(dx: bounds.width * 0.3, dy: bounds.height * 0.3)).cgPath
            innerRing.fillColor = UIColor.white.withAlphaComponent(0.1).cgColor
            innerRing.strokeColor = UIColor.white.withAlphaComponent(0.55).cgColor
            innerRing.lineWidth = 1.5
            innerRing.isHidden = false
        } else {
            innerRing.isHidden = true
        }
        CATransaction.commit()

        // Labels
        let side = min(bounds.width, bounds.height)
        keyLabel.font = .systemFont(ofSize: min(max(side * 0.34, 12), 30), weight: .bold)
        keyLabel.isHidden = false
        caption.isHidden = true
        var keyText = ""
        switch element.kind {
        case .button(let button): keyText = awaiting ? "?" : MapperKeyLabel.short(button.keyName)
        case .draggableButton(let drag):
            keyText = awaiting ? "?" : MapperKeyLabel.short(drag.bindingName ?? "")
            caption.text = "Drag"
            caption.isHidden = false
        case .joystick(let stick):
            keyText = stick.isAnalog ? MapperKeyLabel.short(stick.keyName) : ""
            caption.text = stick.effectiveMode == .FLOATING ? "Floating" : "Joystick"
            caption.isHidden = false
        case .cameraArea(let area):
            keyText = MapperKeyLabel.short(area.keyName)
            caption.text = "Camera"
            caption.isHidden = false
        }
        keyLabel.text = keyText
        keyLabel.isHidden = keyText.isEmpty
        let width = bounds.width, height = bounds.height
        switch tool {
        case .skill:
            keyLabel.frame = CGRect(x: width * 0.1, y: height * 0.05, width: width * 0.8, height: height * 0.35)
        case .joystick, .floatingJoystick:
            if keyText.isEmpty {
                caption.frame = CGRect(x: 0, y: height / 2 - 7, width: width, height: 14)
            } else {
                keyLabel.frame = CGRect(x: width * 0.2, y: height * 0.28, width: width * 0.6, height: height * 0.26)
                caption.frame = CGRect(x: 0, y: height * 0.58, width: width, height: 14)
            }
        case .camera, .drag:
            keyLabel.frame = CGRect(x: width * 0.16, y: height * 0.08, width: width * 0.68, height: height * 0.3)
            caption.frame = CGRect(x: 0, y: height * 0.62, width: width, height: 14)
        }

        badge.isHidden = !conflict
        badge.frame = CGRect(x: bounds.maxX - 14, y: -4, width: 18, height: 18)
        handle.isHidden = !selected || rectangular
        handle.center = CGPoint(x: bounds.maxX, y: bounds.midY)
        bringSubviewToFront(handle)
        for (edge, grip) in edgeHandles {
            grip.isHidden = !selected || !rectangular
            switch edge {
            case .left: grip.center = CGPoint(x: 0, y: bounds.midY)
            case .right: grip.center = CGPoint(x: bounds.maxX, y: bounds.midY)
            case .top: grip.center = CGPoint(x: bounds.midX, y: 0)
            case .bottom: grip.center = CGPoint(x: bounds.midX, y: bounds.maxY)
            }
            bringSubviewToFront(grip)
        }

        showChips(for: element, selectedPart: selected ? selectedPart : nil)
        updatePulse()
        accessibilityLabel = Self.description(of: element, tool: tool, awaiting: awaiting)
        accessibilityValue = selected ? "Selected" : nil
    }

    private static func description(of element: KeymapEditorModel.Element, tool: MapperTool, awaiting: Bool) -> String {
        if awaiting { return "\(tool.title), waiting for a key" }
        switch element.kind {
        case .joystick(let stick) where !stick.isAnalog: return "Joystick, keyboard"
        case .draggableButton(let drag): return "Drag area, \(MapperKeyLabel.long(drag.bindingName ?? ""))"
        default: return "\(tool.title), \(MapperKeyLabel.long(element.title))"
        }
    }

    private func showChips(for element: KeymapEditorModel.Element, selectedPart: KeymapEditorModel.Part?) {
        let parts = KeymapEditorModel.Part.allCases.filter { part in
            if case .draggableButton = element.kind { return false }   // the key is the control's own label
            return element.title(of: part) != nil
        }
        for (part, label) in chips where !parts.contains(part) {
            label.removeFromSuperview()
            chips[part] = nil
        }
        let size = min(max(bounds.width * 0.24, 22), 38)
        for part in parts {
            let chip = chips[part] ?? makeChip(part)
            chip.text = MapperKeyLabel.short(element.title(of: part) ?? "")
            chip.frame = CGRect(x: 0, y: 0, width: size, height: size)
            chip.layer.cornerRadius = size / 2
            chip.layer.borderWidth = selectedPart == part ? 3 : 1
            chip.layer.borderColor = (selectedPart == part ? MapperStyle.selection : UIColor.white.withAlphaComponent(0.6)).cgColor
            chip.font = .systemFont(ofSize: size * 0.42, weight: .bold)
            chip.center = center(of: part, size: size)
        }
    }

    private func center(of part: KeymapEditorModel.Part, size: CGFloat) -> CGPoint {
        let inset = size / 2 + max(bounds.width * 0.04, 3)
        switch part {
        case .up: return CGPoint(x: bounds.midX, y: inset)
        case .down, .grabKey: return CGPoint(x: bounds.midX, y: bounds.height - inset)
        case .left: return CGPoint(x: inset, y: bounds.midY)
        case .right: return CGPoint(x: bounds.width - inset, y: bounds.midY)
        }
    }

    private func makeChip(_ part: KeymapEditorModel.Part) -> UILabel {
        let chip = MapperStyle.makeLabel(size: 12, weight: .bold, alignment: .center)
        chip.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        chip.clipsToBounds = true
        chip.adjustsFontSizeToFitWidth = true
        chip.minimumScaleFactor = 0.4
        chip.isUserInteractionEnabled = true
        chip.tag = part.rawValue
        chip.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tappedChip(_:))))
        addSubview(chip)
        chips[part] = chip
        return chip
    }

    /// A control waiting for a key breathes, so it is clear what the next key press will do.
    private func updatePulse() {
        keyLabel.layer.removeAnimation(forKey: "pulse")
        guard awaiting, !UIAccessibility.isReduceMotionEnabled else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.25
        pulse.duration = 0.7
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        keyLabel.layer.add(pulse, forKey: "pulse")
    }

    // MARK: Gestures

    @objc private func tapped() { onTap?(nil) }

    @objc private func tappedChip(_ recognizer: UITapGestureRecognizer) {
        onTap?(recognizer.view.flatMap { KeymapEditorModel.Part(rawValue: $0.tag) })
    }

    // The handle sits half outside the control; its outer half must be clickable too.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event) || (!handle.isHidden && handle.frame.insetBy(dx: -4, dy: -4).contains(point))
            || edgeHandles.values.contains { !$0.isHidden && $0.frame.insetBy(dx: -4, dy: -4).contains(point) }
    }

    @objc private func resizedEdge(_ recognizer: UIPanGestureRecognizer) {
        guard let canvas = superview, let tag = recognizer.view?.tag,
              let edge = MapperGeometry.Edge(rawValue: tag) else { return }
        switch recognizer.state {
        case .began:
            resizeOrigin = frame
            onMoveBegan?()
        case .changed:
            guard let resizeOrigin else { return }
            onBoundsResize?(MapperGeometry.resizing(resizeOrigin, edge: edge,
                to: recognizer.location(in: canvas), in: canvas.bounds.size))
        case .ended, .cancelled, .failed:
            resizeOrigin = nil
            onResizeEnded?()
        default: break
        }
    }

    @objc private func resized(_ recognizer: UIPanGestureRecognizer) {
        guard let canvas = superview else { return }
        switch recognizer.state {
        case .began, .changed:
            let point = recognizer.location(in: canvas)
            onResize?(CGVector(dx: point.x - center.x, dy: point.y - center.y))
        case .ended, .cancelled, .failed:
            onResizeEnded?()
        default:
            break
        }
    }

    @objc private func scrolledWheel(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            scrolled = 0
        case .changed:
            scrolled += recognizer.translation(in: self).y
            recognizer.setTranslation(.zero, in: self)
            // A notch is about ten points; up (away from the player) makes it larger.
            while abs(scrolled) >= 10 {
                onScrollResize?(scrolled < 0)
                scrolled += scrolled < 0 ? 10 : -10
            }
        default:
            break
        }
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        guard let canvas = superview else { return }
        switch recognizer.state {
        case .began:
            onMoveBegan?()
        case .changed:
            onMove?(recognizer.translation(in: canvas))
            recognizer.setTranslation(.zero, in: canvas)
        case .ended, .cancelled, .failed:
            onMoveEnded?()
        default:
            break
        }
    }
}
#endif
