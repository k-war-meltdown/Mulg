#if canImport(UIKit) && !os(watchOS)
import MulgContracts
import MulgEngine
import MulgKeymaps
import UIKit

/// The control editor the mapper supplies to the controls module. It opens a tinted layer over the game
/// (a window above the game's, like the built-in editor's), draws the session on it, and forwards the
/// keys, mouse buttons and controller buttons the input router hands over while it is open.
@MainActor
public final class MapperEditor: ControlEditing {
    private var settings: MapperSettings
    private var session: MapperSession?
    private var window: UIWindow?
    private weak var previousKeyWindow: UIWindow?
    private var canvas: MapperCanvasView?
    private var metrics: ScreenMetrics?

    public init(settings: MapperSettings) {
        self.settings = settings
    }

    func apply(settings: MapperSettings) {
        self.settings = settings
        canvas?.apply(settings: settings)
    }

    // MARK: ControlEditing

    public var isOpen: Bool { session != nil }

    /// The draft as it would be saved (a control still waiting for its key is left out).
    public var model: KeymapEditorModel? { session?.finalModel }

    @discardableResult
    public func open(keymap: KeymappingData, profile: String, host: ControlEditingHost) -> Bool {
        guard session == nil, let gameWindow = Self.gameWindow(), let scene = gameWindow.windowScene else { return false }
        let geometry = Self.geometry(of: gameWindow)
        metrics = geometry.metrics
        previousKeyWindow = gameWindow

        // Ending the session closes the window the Save button lives in, so it waits for the button's
        // action to return.
        let deferred = ControlEditingHost(
            profiles: host.profiles, switchProfile: host.switchProfile, createProfile: host.createProfile,
            finish: { save in Task { @MainActor in host.finish(save) } })
        let session = MapperSession(keymap: keymap, profile: profile, host: deferred) { [weak self] map in
            guard let metrics = self?.metrics else { return map }
            // Edit the map where it sits on this screen; saving records this screen's shape.
            return map.withAdaptiveLayouts().fitted(toWidth: metrics.canvasWidth, height: metrics.height)
        }
        self.session = session

        let canvas = MapperCanvasView(session: session, settings: settings)
        canvas.editor = self
        canvas.renderAspect = geometry.metrics.renderAspect
        canvas.frame = geometry.frame
        session.onChange = { [weak canvas] in canvas?.render() }
        self.canvas = canvas

        let window = UIWindow(windowScene: scene)
        window.frame = gameWindow.frame
        window.windowLevel = .alert + 1
        let controller = MapperViewController(session: session)
        let container = UIView(frame: gameWindow.bounds)
        container.backgroundColor = .clear
        container.addSubview(canvas)
        controller.view = container
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        canvas.render()
        if !UIAccessibility.isReduceMotionEnabled {
            container.alpha = 0
            UIView.animate(withDuration: 0.15) { container.alpha = 1 }
        }
        return true
    }

    public func replace(keymap: KeymappingData, profile: String) {
        session?.replace(keymap: keymap, profile: profile)
    }

    /// Closes the editor and returns the draft and whether it changed.
    public func close() -> (keymap: KeymappingData, changed: Bool)? {
        guard let session else { return nil }
        let final = session.finalModel
        let result = (keymap: final.keymap(), changed: final.hasChanges)
        session.onChange = nil
        canvas?.dismiss()
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        canvas = nil
        self.session = nil
        metrics = nil
        previousKeyWindow?.makeKeyAndVisible()
        return result
    }

    // MARK: Input the router hands over

    public var capturesText: Bool { session?.capturesText ?? false }

    public func editorKey(code: UInt16, ctrlModified: Bool) -> Bool {
        refreshViewportGeometry()
        return session?.bindKey(virtualKeyCode: code, control: ctrlModified) ?? false
    }

    /// A mouse button other than the left one. It binds the selected control when that takes one;
    /// otherwise a right click drops a skill button under the pointer.
    public func editorMouseButton(_ button: Int) -> Bool {
        refreshViewportGeometry()
        guard let session else { return false }
        return session.mouseButton(button, pointerAt: canvas?.pointer ?? CGPoint(x: 0.5, y: 0.5),
                                   overSelection: canvas?.pointerIsOverSelection ?? false)
    }

    public func controllerElement(_ name: String) {
        session?.bindController(name)
    }

    // The built-in editor's menu shortcuts map onto the same session.
    public func removeSelected() { session?.deleteSelected() }
    public func resizeSelected(larger: Bool) { session?.resizeSelected(larger: larger) }
    public func toggleJoystickMode() { session?.toggleSelectedMode() }
    public func toggleButtonHold() { session?.toggleSelectedMode() }
    public func showLayer(offset: Int) { session?.showLayer(offset: offset) }
    public func addLayer() { session?.addLayer() }

    // MARK: The game's window and shape

    /// Keeps the overlay and the draft in the same shape as the game's picture: when the window or the
    /// render size changes, the canvas follows and the draft is refitted (which is not an edit).
    func refreshViewportGeometry() {
        guard let session, let gameWindow = previousKeyWindow, let canvas else { return }
        let geometry = Self.geometry(of: gameWindow)
        guard geometry.frame.width.isFinite, geometry.frame.height.isFinite,
              geometry.frame.width > 0, geometry.frame.height > 0 else { return }
        let changed = geometry.metrics != metrics || canvas.frame != geometry.frame
        guard changed else { return }
        // Reflowing drops the undo history: only a new render shape needs it, not a moved or same-shape window.
        let reshaped = metrics.map { abs($0.renderAspect - geometry.metrics.renderAspect) > 0.0001 } ?? true
        metrics = geometry.metrics
        canvas.renderAspect = geometry.metrics.renderAspect
        if reshaped { session.reflow(toAspect: geometry.metrics.renderAspect) }
        if canvas.frame != geometry.frame { canvas.frame = geometry.frame }
    }

    /// The canvas rectangle (the game's rendered area in window coordinates) and its metrics.
    private static func geometry(of gameWindow: UIWindow) -> (frame: CGRect, metrics: ScreenMetrics) {
        let viewport = GameViewport.shared
        let surface = viewport.captureSurface(in: gameWindow)
        let bounds = viewport.bounds.isEmpty ? gameWindow.bounds : viewport.bounds
        let origin = surface?.windowPoint(.zero) ?? .zero
        let end = surface?.windowPoint(CGPoint(x: bounds.width, y: bounds.height))
            ?? CGPoint(x: gameWindow.bounds.width, y: gameWindow.bounds.height)
        return (CGRect(x: origin.x, y: origin.y, width: end.x - origin.x, height: end.y - origin.y),
                ScreenMetrics(bounds: bounds, renderSize: viewport.pixelSize))
    }

    private static func gameWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }
}

/// Holds the key commands of the overlay: ⌘Z undoes, ⇧⌘Z redoes.
final class MapperViewController: UIViewController {
    private let session: MapperSession

    init(session: MapperSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override var keyCommands: [UIKeyCommand]? {
        let undo = UIKeyCommand(title: "Undo", action: #selector(undo), input: "z", modifierFlags: .command)
        let redo = UIKeyCommand(title: "Redo", action: #selector(redo), input: "z", modifierFlags: [.command, .shift])
        undo.wantsPriorityOverSystemBehavior = true
        redo.wantsPriorityOverSystemBehavior = true
        return [undo, redo]
    }

    @objc private func undo() {
        if !session.capturesText { session.undo() }
    }

    @objc private func redo() {
        if !session.capturesText { session.redo() }
    }
}
#endif
