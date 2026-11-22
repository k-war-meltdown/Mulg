#if canImport(UIKit) && !os(watchOS)
import MulgContracts
import MulgEngine
import UIKit

/// The in-game keymap editor (⌘K), ported from upstream Editor/ in Swift 6.
///
/// It opens a window over the game showing every keymap element. Click an element to select
/// it, then press a key, a mouse button or a controller button to bind it; drag to move it;
/// click empty space to add an element. The editing rules live in `KeymapEditorModel`.
///
/// Changes from upstream:
/// - the add menu is a plain row of labelled buttons instead of the animated circle menu
///   (about 800 lines upstream), and it names what each button adds;
/// - joystick directions and a draggable button's key are selected by clicking them, and the
///   selection is shown, so it is clear which key the next press changes;
/// - a banner says what to do and which element is selected;
/// - closing reports whether the keymap changed, so an unchanged keymap is not rewritten.
@MainActor
public final class KeymapEditor: KeymapEditorInput {
    public private(set) var model: KeymapEditorModel?
    private var window: UIWindow?
    private weak var previousKeyWindow: UIWindow?
    private var canvas: EditorCanvasView?
    private var editorMetrics: ScreenMetrics?

    public init() {}

    public var isOpen: Bool { model != nil }

    /// Opens the editor over the game's key window. Returns false when there is no window.
    @discardableResult
    public func open(keymap: KeymappingData, keymapName: String) -> Bool {
        guard model == nil, let gameWindow = Self.gameWindow(), let scene = gameWindow.windowScene else { return false }
        // Edit the keymap where it sits on this screen; saving records this screen's shape.
        let viewport = GameViewport.shared
        let surface = viewport.captureSurface(in: gameWindow)
        let bounds = viewport.bounds.isEmpty ? gameWindow.bounds : viewport.bounds
        let origin = surface?.windowPoint(.zero) ?? .zero
        let end = surface?.windowPoint(CGPoint(x: bounds.width, y: bounds.height))
            ?? CGPoint(x: gameWindow.bounds.width, y: gameWindow.bounds.height)
        let canvasFrame = CGRect(x: origin.x, y: origin.y, width: end.x - origin.x, height: end.y - origin.y)
        let metrics = ScreenMetrics(bounds: bounds, renderSize: viewport.pixelSize)
        editorMetrics = metrics
        model = KeymapEditorModel(keymap: keymap.withAdaptiveLayouts()
            .fitted(toWidth: metrics.canvasWidth, height: metrics.height))
        model?.select(nil)
        previousKeyWindow = gameWindow

        let window = UIWindow(windowScene: scene)
        window.frame = gameWindow.frame
        window.windowLevel = .alert + 1
        let controller = UIViewController()
        let container = UIView(frame: gameWindow.bounds)
        container.backgroundColor = .clear
        let canvas = EditorCanvasView(frame: canvasFrame)
        canvas.editor = self
        canvas.renderAspect = metrics.renderAspect
        canvas.keymapName = keymapName
        container.addSubview(canvas)
        controller.view = container
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        self.canvas = canvas
        render()
        return true
    }

    /// Closes the editor and returns the edited keymap, and whether it changed.
    public func close() -> (keymap: KeymappingData, changed: Bool)? {
        guard let model else { return nil }
        canvas?.hidePalette()
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        canvas = nil
        self.model = nil
        editorMetrics = nil
        previousKeyWindow?.makeKeyAndVisible()
        return (model.keymap(), model.hasChanges)
    }

    // MARK: Commands (menu)

    public func removeSelected() {
        mutate { $0.removeSelected() }
    }

    public func resizeSelected(larger: Bool) {
        mutate { $0.resizeSelected(larger: larger) }
    }

    public func toggleJoystickMode() {
        mutate { $0.toggleJoystickMode() }
    }

    public func toggleButtonHold() {
        mutate { $0.toggleButtonHold() }
    }

    public func showLayer(offset: Int) {
        canvas?.hidePalette()
        mutate { $0.showLayer(offset: offset) }
    }

    public func addLayer() {
        canvas?.hidePalette()
        mutate { $0.addLayer() }
    }

    // MARK: Input (KeymapEditorInput)

    /// Keys that can't be bound (upstream's list): Control, Option, Command and Print Screen.
    /// Shift stays bindable: Genshin sprints with Left Shift.
    static let unbindableKeyCodes: Set<Int> = [224, 226, 227, 228, 230, 231, 70]

    public func editorKey(code: UInt16, ctrlModified: Bool) -> Bool {
        // With nothing selected, a key sets the shown layer's hold key (the model decides).
        guard model != nil, let keymapCode = KeymapKeyNames.keymapCode(forVirtualKeyCode: code),
              !Self.unbindableKeyCodes.contains(keymapCode),
              let name = KeymapKeyNames.name(forKeyCode: keymapCode) else { return false }
        if ctrlModified {
            // Upstream: Control+key is bound by name, with no key code.
            mutate { $0.assignKey(code: KeymapKeyNames.defaultCode, name: "⌃" + name) }
        } else {
            mutate { $0.assignKey(code: keymapCode, name: name) }
        }
        return true
    }

    public func editorMouseButton(_ button: Int) -> Bool {
        guard model != nil else { return false }
        let code = KeymapKeyNames.code(forMouseButton: button) ?? KeymapKeyNames.defaultCode
        mutate { $0.assignMouseButton(code: code, name: KeymapKeyNames.name(forMouseButton: button)) }
        return true
    }

    /// A controller element was pressed or moved ("Button A", "Left Thumbstick").
    public func controllerElement(_ name: String) {
        mutate { $0.assignControllerElement(name) }
    }

    // MARK: Called by the views

    func selectElement(_ id: Int?, part: KeymapEditorModel.Part? = nil) {
        mutate { $0.select(id, part: part) }
    }

    func add(_ element: KeymapEditorModel.NewElement, at point: CGPoint) {
        refreshViewportGeometry()
        guard let canvas, canvas.bounds.width > 0, canvas.bounds.height > 0 else { return }
        let relative = CGPoint(x: point.x / canvas.bounds.width, y: point.y / canvas.bounds.height)
        mutate { $0.add(element, at: relative) }
    }

    /// Moves the selected element during a drag, updating only its view.
    func drag(_ id: Int, by translation: CGPoint) {
        refreshViewportGeometry()
        guard let canvas, canvas.bounds.width > 0, canvas.bounds.height > 0 else { return }
        if model?.focused != id {
            model?.select(id)
            render()
        }
        model?.moveSelected(by: CGVector(dx: translation.x / canvas.bounds.width, dy: translation.y / canvas.bounds.height))
        if let element = model?.element(id) {
            canvas.updatePosition(of: element)
        }
    }

    private func mutate(_ change: (inout KeymapEditorModel) -> Void) {
        refreshViewportGeometry()
        guard var model else { return }
        change(&model)
        self.model = model
        render()
    }

    /// Keep the draft and overlay in the same output-aspect plane as gameplay controls.
    /// Called by overlay layout and before input, including pixel-only render changes.
    func refreshViewportGeometry() {
        guard model != nil, let gameWindow = previousKeyWindow, let canvas else { return }
        let viewport = GameViewport.shared
        let bounds = viewport.bounds.isEmpty ? gameWindow.bounds : viewport.bounds
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return }
        let metrics = ScreenMetrics(bounds: bounds, renderSize: viewport.pixelSize)
        let surface = viewport.captureSurface(in: gameWindow)
        let origin = surface?.windowPoint(.zero) ?? .zero
        let end = surface?.windowPoint(CGPoint(x: bounds.width, y: bounds.height))
            ?? CGPoint(x: gameWindow.bounds.width, y: gameWindow.bounds.height)
        let frame = CGRect(x: origin.x, y: origin.y, width: end.x - origin.x, height: end.y - origin.y)
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else { return }
        let changed = metrics != editorMetrics || canvas.frame != frame
        guard changed else { return }
        editorMetrics = metrics
        model?.reflow(toAspect: metrics.renderAspect)
        canvas.renderAspect = metrics.renderAspect
        if canvas.frame != frame { canvas.frame = frame }
        render()
    }

    private func render() {
        guard let model, let canvas else { return }
        canvas.render(model)
    }

    static func gameWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }
}

// MARK: - Views

/// The editor's full-screen view: the elements, the banner and the add menu.
final class EditorCanvasView: UIView {
    weak var editor: KeymapEditor?
    var keymapName = ""
    var renderAspect: Double?
    private var elementViews: [Int: EditorElementView] = [:]
    private let banner = UILabel()
    private var palette: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = UIColor.black.withAlphaComponent(0.2)
        banner.numberOfLines = 0
        banner.textAlignment = .center
        banner.font = .systemFont(ofSize: 13, weight: .medium)
        banner.textColor = .white
        banner.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        banner.layer.cornerRadius = 8
        banner.clipsToBounds = true
        addSubview(banner)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tappedBackground(_:))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func render(_ model: KeymapEditorModel) {
        let ids = Set(model.visibleElements.map(\.id))
        for (id, view) in elementViews where !ids.contains(id) {
            view.removeFromSuperview()
            elementViews[id] = nil
        }
        let conflicting = model.conflictingElements
        for element in model.visibleElements {
            let view = elementViews[element.id] ?? makeView(for: element.id)
            view.show(element, selected: model.focused == element.id, conflict: conflicting.contains(element.id),
                      selectedPart: model.focused == element.id ? model.focusedPart : nil,
                      frame: frame(for: element))
        }
        bringSubviewToFront(banner)
        banner.text = bannerText(model)
        setNeedsLayout()
    }

    func updatePosition(of element: KeymapEditorModel.Element) {
        elementViews[element.id]?.frame = frame(for: element)
    }

    private func makeView(for id: Int) -> EditorElementView {
        let view = EditorElementView(id: id)
        view.onSelect = { [weak self] part in self?.editor?.selectElement(id, part: part) }
        view.onDrag = { [weak self] translation in self?.editor?.drag(id, by: translation) }
        addSubview(view)
        elementViews[id] = view
        return view
    }

    private func frame(for element: KeymapEditorModel.Element) -> CGRect {
        let renderSize = renderAspect.map { CGSize(width: CGFloat($0) * bounds.height, height: bounds.height) }
        let metrics = ScreenMetrics(bounds: bounds, renderSize: renderSize)
        let size = metrics.size(element.transform.size)
        let width = size * metrics.horizontalUnitScale
        return CGRect(x: element.transform.xCoord * bounds.width - width / 2,
                      y: element.transform.yCoord * bounds.height - size / 2,
                      width: width, height: size)
    }

    private func bannerText(_ model: KeymapEditorModel) -> String {
        var lines = ["Keymap “\(keymapName)”, \(model.layerTitle): click empty space to add, click an element and press a key to bind it, drag to move. ⌘L next layer, ⇧⌘L new layer."]
        let conflicts = model.conflicts
        if !conflicts.isEmpty {
            lines.append("⚠︎ Used twice: " + conflicts.prefix(3).map(\.description).joined(separator: "; "))
        }
        if let id = model.focused, let element = model.element(id) {
            switch element.kind {
            case .joystick:
                lines.append("Joystick: click a direction to rebind it, or press a mouse button or move a stick to drive it. ⌘J fixed/floating.")
            case .draggableButton:
                lines.append("Draggable button: press the key that grabs it; a mouse button or stick sets what moves it.")
            case .cameraArea:
                lines.append("Camera: the mouse or a stick turns the camera. Press a key to make it a draggable button.")
            case .button:
                lines.append("Button: press a key, mouse button or controller button.")
            }
            lines.append("⌘↑ ⌘↓ size · ⌘⌫ delete · ⌘K save and close")
        } else {
            lines.append("⌘K saves and closes the editor.")
        }
        return lines.joined(separator: "\n")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        editor?.refreshViewportGeometry()
        let width = min(bounds.width - 32, 640)
        let height = banner.sizeThatFits(CGSize(width: width - 16, height: .greatestFiniteMagnitude)).height + 12
        banner.frame = CGRect(x: (bounds.width - width) / 2, y: max(safeAreaInsets.top, 8) + 4, width: width, height: height)
    }

    // MARK: Adding elements

    @objc private func tappedBackground(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        if palette != nil {
            hidePalette()
            return
        }
        editor?.selectElement(nil)
        showPalette(at: point)
    }

    func hidePalette() {
        palette?.removeFromSuperview()
        palette = nil
    }

    private func showPalette(at point: CGPoint) {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.layoutMargins = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.isLayoutMarginsRelativeArrangement = true
        stack.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        stack.layer.cornerRadius = 12
        for item in KeymapEditorModel.NewElement.allCases {
            var configuration = UIButton.Configuration.filled()
            configuration.image = UIImage(systemName: item.symbol)
            configuration.imagePlacement = .top
            configuration.imagePadding = 4
            configuration.title = item.title
            configuration.baseBackgroundColor = UIColor.darkGray
            configuration.baseForegroundColor = .white
            let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
                self?.hidePalette()
                self?.editor?.add(item, at: point)
            })
            stack.addArrangedSubview(button)
        }
        let size = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let x = min(max(point.x - size.width / 2, 8), bounds.width - size.width - 8)
        let y = min(max(point.y - size.height / 2, 8), bounds.height - size.height - 8)
        stack.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        addSubview(stack)
        palette = stack
    }
}

/// One element: a circle with its binding, plus direction or grab-key parts.
final class EditorElementView: UIView {
    let id: Int
    var onSelect: ((KeymapEditorModel.Part?) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    private let title = UILabel()
    private var partViews: [KeymapEditorModel.Part: UILabel] = [:]

    init(id: Int) {
        self.id = id
        super.init(frame: .zero)
        clipsToBounds = false
        title.textAlignment = .center
        title.textColor = .white
        title.adjustsFontSizeToFitWidth = true
        title.minimumScaleFactor = 0.2
        title.numberOfLines = 2
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        addSubview(title)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged(_:))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show(_ element: KeymapEditorModel.Element, selected: Bool, conflict: Bool,
              selectedPart: KeymapEditorModel.Part?, frame: CGRect) {
        self.frame = frame
        layer.cornerRadius = frame.width / 2
        layer.borderWidth = selected || conflict ? 3 : 1
        let border: UIColor = selected ? .systemPink : conflict ? .systemRed : UIColor.white.withAlphaComponent(0.6)
        layer.borderColor = border.cgColor
        switch element.kind {
        case .cameraArea:
            backgroundColor = UIColor.systemBlue.withAlphaComponent(0.35)
        case .joystick:
            backgroundColor = UIColor.systemGreen.withAlphaComponent(0.35)
        default:
            backgroundColor = UIColor.darkGray.withAlphaComponent(0.8)
        }
        title.text = element.title
        title.frame = bounds.insetBy(dx: bounds.width * 0.18, dy: bounds.height * 0.3)

        let parts = KeymapEditorModel.Part.allCases.filter { element.title(of: $0) != nil }
        for (part, view) in partViews where !parts.contains(part) {
            view.removeFromSuperview()
            partViews[part] = nil
        }
        let partSize = max(18, min(frame.width * 0.3, 44))
        for part in parts {
            let label = partViews[part] ?? makePartLabel(part)
            label.text = element.title(of: part)
            label.frame = CGRect(origin: .zero, size: CGSize(width: partSize, height: partSize))
            label.layer.cornerRadius = partSize / 2
            label.layer.borderWidth = selectedPart == part ? 3 : 0
            label.layer.borderColor = UIColor.systemPink.cgColor
            label.center = center(of: part)
        }
    }

    private func makePartLabel(_ part: KeymapEditorModel.Part) -> UILabel {
        let label = UILabel()
        label.textAlignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .bold)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.3
        label.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        label.clipsToBounds = true
        label.isUserInteractionEnabled = true
        label.tag = part.rawValue
        label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tappedPart(_:))))
        addSubview(label)
        partViews[part] = label
        return label
    }

    private func center(of part: KeymapEditorModel.Part) -> CGPoint {
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        let inset = bounds.width * 0.2
        switch part {
        case .up: return CGPoint(x: middle.x, y: inset)
        case .down: return CGPoint(x: middle.x, y: bounds.height - inset)
        case .left: return CGPoint(x: inset, y: middle.y)
        case .right: return CGPoint(x: bounds.width - inset, y: middle.y)
        case .grabKey: return CGPoint(x: middle.x, y: bounds.height - inset)
        }
    }

    @objc private func tapped() {
        onSelect?(nil)
    }

    @objc private func tappedPart(_ recognizer: UITapGestureRecognizer) {
        onSelect?(recognizer.view.flatMap { KeymapEditorModel.Part(rawValue: $0.tag) })
    }

    @objc private func dragged(_ recognizer: UIPanGestureRecognizer) {
        guard let superview else { return }
        let translation = recognizer.translation(in: superview)
        onDrag?(translation)
        recognizer.setTranslation(.zero, in: superview)
    }
}

// MARK: - The editor the controls module hosts

extension KeymapEditor: ControlEditing {
    /// The built-in editor has no profile controls: it edits the active profile and saves on close.
    public func open(keymap: KeymappingData, profile: String, host: ControlEditingHost) -> Bool {
        open(keymap: keymap, keymapName: profile)
    }

    public func replace(keymap: KeymappingData, profile: String) {
        guard isOpen else { return }
        _ = close()
        _ = open(keymap: keymap, keymapName: profile)
    }
}
#endif
