#if canImport(UIKit) && !os(watchOS)
import MulgContracts
import MulgEngine
import MulgKeymaps
import UIKit

/// The tinted layer over the game: the controls, the toolbar and whatever panel is open. It covers the
/// game's rendered area at whatever size the window has, and keeps the controls where the game's
/// own HUD would be.
final class MapperCanvasView: UIView, UIGestureRecognizerDelegate {
    weak var editor: MapperEditor?
    var renderAspect: Double?
    /// Where the pointer last was over the canvas, as fractions of it (a right click drops a skill there).
    private(set) var pointer = CGPoint(x: 0.5, y: 0.5)

    private let session: MapperSession
    private var showTips: Bool
    private var controlViews: [Int: MapperControlView] = [:]
    private let toolbar: MapperToolbarView
    private let tip = MapperCapsuleView()
    private let messageCapsule = MapperCapsuleView()
    private let warning = MapperCapsuleView()
    private var inspector: MapperInspectorView?
    private var picker: MapperPickerView?
    private var pickerPoint = CGPoint.zero
    private var prompt: MapperPromptView?
    private var shownMessageID = 0
    private var messageHide: DispatchWorkItem?

    init(session: MapperSession, settings: MapperSettings) {
        self.session = session
        showTips = settings.showTips
        toolbar = MapperToolbarView(session: session)
        super.init(frame: .zero)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = UIColor.black.withAlphaComponent(settings.tintOpacity)
        addSubview(toolbar)
        addSubview(tip)
        addSubview(messageCapsule)
        addSubview(warning)
        messageCapsule.alpha = 0
        warning.isHidden = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        addGestureRecognizer(hover)
        isAccessibilityElement = false
        accessibilityViewIsModal = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func apply(settings: MapperSettings) {
        showTips = settings.showTips
        backgroundColor = UIColor.black.withAlphaComponent(settings.tintOpacity)
        render()
    }

    // MARK: Drawing the session

    /// Brings every view in line with the session. Cheap enough to run on every change; a drag only
    /// moves the control and its panel.
    func render() {
        if session.isMoving {
            if let id = session.selectedID, let element = session.elements.first(where: { $0.id == id }) {
                controlViews[id]?.show(element, tool: Self.tool(of: element), selected: true,
                    awaiting: session.unbound.contains(id), conflict: session.conflictingIDs.contains(id),
                    selectedPart: session.selectedPart, frame: frame(of: element))
            }
            layoutPanels()
            return
        }
        let elements = session.elements
        let ids = Set(elements.map(\.id))
        for (id, view) in controlViews where !ids.contains(id) {
            view.removeFromSuperview()
            controlViews[id] = nil
        }
        let conflicts = session.conflictingIDs
        for element in elements {
            let view = controlViews[element.id] ?? makeControlView(for: element.id)
            view.show(element, tool: Self.tool(of: element), selected: session.selectedID == element.id,
                      awaiting: session.unbound.contains(element.id), conflict: conflicts.contains(element.id),
                      selectedPart: session.selectedPart, frame: frame(of: element))
            insertSubview(view, belowSubview: toolbar)
        }
        toolbar.update()
        renderInspector()
        renderPicker()
        renderPrompt()
        renderCaptions()
        setNeedsLayout()
    }

    static func tool(of element: KeymapEditorModel.Element) -> MapperTool {
        switch element.kind {
        case .button: .skill
        case .joystick(let stick): stick.effectiveMode == .FLOATING ? .floatingJoystick : .joystick
        case .cameraArea: .camera
        case .draggableButton: .drag
        }
    }

    private var metrics: ScreenMetrics {
        let renderSize = renderAspect.map { CGSize(width: CGFloat($0) * bounds.height, height: bounds.height) }
        return ScreenMetrics(bounds: bounds, renderSize: renderSize)
    }

    private func frame(of element: KeymapEditorModel.Element) -> CGRect {
        MapperGeometry.frame(of: element.transform, canvas: bounds.size, metrics: metrics, drawScale: Self.drawScale(of: element))
    }

    private static func drawScale(of element: KeymapEditorModel.Element) -> CGFloat {
        if case .joystick = element.kind { return MapperGeometry.joystickDrawScale }
        return 1
    }

    private func makeControlView(for id: Int) -> MapperControlView {
        let view = MapperControlView(id: id)
        view.onTap = { [weak self] part in self?.session.select(id, part: part) }
        view.onMoveBegan = { [weak self] in
            guard let self else { return }
            if self.session.selectedID != id { self.session.select(id) }
            self.session.beginMove()
        }
        view.onMove = { [weak self] translation in
            guard let self, self.bounds.width > 0, self.bounds.height > 0 else { return }
            self.session.moveSelected(by: CGVector(dx: translation.x / self.bounds.width, dy: translation.y / self.bounds.height))
        }
        view.onMoveEnded = { [weak self] in self?.session.endMove() }
        // The handle on the selected control's edge: the shape follows it.
        view.onResize = { [weak self] offset in
            guard let self, let element = self.session.model.element(id) else { return }
            if self.session.selectedID != id { self.session.select(id) }
            self.session.setSelectedSize(MapperGeometry.size(forHandleOffset: offset, metrics: self.metrics,
                                                             drawScale: Self.drawScale(of: element)))
        }
        view.onResizeEnded = { [weak self] in self?.session.endMove() }
        view.onBoundsResize = { [weak self] frame in
            guard let self, self.bounds.width > 0, self.bounds.height > 0, self.metrics.percent > 0 else { return }
            self.session.setSelectedBounds(center: CGPoint(x: frame.midX / self.bounds.width, y: frame.midY / self.bounds.height),
                width: frame.width / self.metrics.horizontalUnitScale / self.metrics.percent,
                height: frame.height / self.metrics.percent)
        }
        // Scrolling over a control resizes it, a step per notch.
        view.onScrollResize = { [weak self] larger in
            guard let self else { return }
            if self.session.selectedID != id { self.session.select(id) }
            self.session.resizeSelected(larger: larger)
        }
        addSubview(view)
        controlViews[id] = view
        return view
    }

    private func renderInspector() {
        guard let info = session.inspector, session.prompt == .none || isPicker(session.prompt) else {
            inspector?.removeFromSuperview()
            inspector = nil
            return
        }
        let panel: MapperInspectorView
        if let existing = inspector {
            panel = existing
        } else {
            panel = MapperInspectorView(session: session)
            inspector = panel
            panel.alpha = 0
            addSubview(panel)
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.12) { panel.alpha = 1 }
        }
        panel.show(info)
        bringSubviewToFront(panel)
    }

    private func isPicker(_ prompt: MapperSession.Prompt) -> Bool {
        if case .picker = prompt { return true }
        return false
    }

    private func renderPicker() {
        guard case .picker(let point) = session.prompt else {
            picker?.removeFromSuperview()
            picker = nil
            return
        }
        pickerPoint = point
        if picker == nil {
            let view = MapperPickerView(session: session, point: point)
            view.alpha = 0
            addSubview(view)
            picker = view
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.12) { view.alpha = 1 }
        }
        if let picker { bringSubviewToFront(picker) }
    }

    private func renderPrompt() {
        switch session.prompt {
        case .naming, .confirmDiscard, .confirmLeave:
            let view = prompt ?? MapperPromptView(session: session)
            if prompt == nil {
                prompt = view
                addSubview(view)
            }
            view.frame = bounds
            view.show(session.prompt, message: session.message)
            bringSubviewToFront(view)
        case .none, .picker:
            prompt?.dismiss()
            prompt?.removeFromSuperview()
            prompt = nil
        }
    }

    private func renderCaptions() {
        let hasPanel = session.inspector != nil || session.prompt != .none
        if showTips, !hasPanel, let text = session.tip {
            tip.show(text)
            tip.isHidden = false
        } else {
            tip.isHidden = true
        }
        // Keys used twice stay on screen until they are fixed.
        let conflict = session.conflictSummary
        if let summary = conflict, session.prompt == .none {
            warning.show("Used twice: \(summary)", symbol: "exclamationmark.triangle.fill", tint: .systemYellow)
            warning.isHidden = false
        } else {
            warning.isHidden = true
        }
        // A message (saved, switched, failed) shows for a few seconds. A failure while a question is
        // open is shown in the question itself.
        if let message = session.message, message.id != shownMessageID, !(prompt != nil && message.isError) {
            shownMessageID = message.id
            messageHide?.cancel()
            messageCapsule.show(message.text, symbol: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                                tint: message.isError ? .systemOrange : .systemGreen)
            messageCapsule.alpha = 1
            let hide = DispatchWorkItem { [weak self] in
                UIView.animate(withDuration: 0.25, animations: { self?.messageCapsule.alpha = 0 },
                               completion: { _ in self?.setNeedsLayout() })
            }
            messageHide = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + (message.isError ? 5 : 3), execute: hide)
        }
        bringSubviewToFront(toolbar)
        bringSubviewToFront(messageCapsule)
        bringSubviewToFront(warning)
        if let prompt { bringSubviewToFront(prompt) }
    }

    func dismiss() {
        messageHide?.cancel()
        messageHide = nil
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        editor?.refreshViewportGeometry()
        for element in session.elements {
            controlViews[element.id]?.frame = frame(of: element)
        }
        layoutPanels()
        prompt?.frame = bounds
    }

    private func layoutPanels() {
        let safeTop = max(safeAreaInsets.top, 8)
        let toolbarSize = toolbar.size(fitting: bounds.width - 24)
        toolbar.frame = CGRect(x: (bounds.width - toolbarSize.width) / 2, y: safeTop + 4,
                               width: toolbarSize.width, height: toolbarSize.height)
        let messageSize = messageCapsule.size(fitting: bounds.width - 32)
        messageCapsule.frame = CGRect(x: (bounds.width - messageSize.width) / 2, y: toolbar.frame.maxY + 8,
                                      width: messageSize.width, height: messageSize.height)
        let warningSize = warning.size(fitting: bounds.width - 32)
        let warningTop = (messageCapsule.alpha > 0 ? messageCapsule.frame.maxY : toolbar.frame.maxY) + 8
        warning.frame = CGRect(x: (bounds.width - warningSize.width) / 2, y: warningTop,
                               width: warningSize.width, height: warningSize.height)
        let tipSize = tip.size(fitting: bounds.width - 32)
        tip.frame = CGRect(x: (bounds.width - tipSize.width) / 2, y: bounds.height - tipSize.height - max(safeAreaInsets.bottom, 14) - 6,
                           width: tipSize.width, height: tipSize.height)
        if let inspector, let id = session.selectedID, let element = session.elements.first(where: { $0.id == id }) {
            let size = inspector.size(fitting: bounds.width - 24)
            inspector.frame = MapperGeometry.inspectorFrame(
                size: size, near: frame(of: element), in: bounds,
                keepClear: toolbar.frame.union(warning.isHidden ? (messageCapsule.alpha > 0 ? messageCapsule.frame : toolbar.frame) : warning.frame))
        }
        if let picker {
            let anchor = CGPoint(x: pickerPoint.x * bounds.width, y: pickerPoint.y * bounds.height)
            picker.frame = MapperGeometry.popoverFrame(size: picker.preferredSize, anchor: anchor, in: bounds)
        }
    }

    // MARK: Pointer and background clicks

    /// Whether the pointer is on the selected control (a right click there binds the right mouse button to it).
    var pointerIsOverSelection: Bool {
        guard let id = session.selectedID, let view = controlViews[id], bounds.width > 0, bounds.height > 0 else { return false }
        let point = CGPoint(x: pointer.x * bounds.width, y: pointer.y * bounds.height)
        return view.frame.insetBy(dx: -6, dy: -6).contains(point)
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        pointer = MapperGeometry.relative(point, in: bounds.size)
        session.clickEmpty(at: pointer)
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        guard recognizer.state == .changed || recognizer.state == .began else { return }
        pointer = MapperGeometry.relative(recognizer.location(in: self), in: bounds.size)
    }

    /// Only a click on the tinted background is "empty space"; controls and panels handle their own.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touch.view === self
    }
}
#endif
