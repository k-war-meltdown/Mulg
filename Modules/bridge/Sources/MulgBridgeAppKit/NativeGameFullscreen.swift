#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import ObjectiveC
import OSLog

/// Keeps one game window eligible for native fullscreen in both runtime backends.
/// Green clicks request AppKit's native Space transition; UIKit keeps its window and delegate.
@MainActor
final class NativeGameFullscreen: NSObject {
    private weak var window: NSWindow?
    private let originalBehavior: NSWindow.CollectionBehavior
    private var appliedBehavior: NSWindow.CollectionBehavior?
    private var windowedLevel: NSWindow.Level?
    private var transitioning = false
    private var observers: [NSObjectProtocol] = []
    private var mouseMonitor: Any?
    private var zoomClickMonitor: Any?
    private let greenInteraction: (Bool) -> Void
    @MainActor private final class ButtonRoute {
        weak var button: NSButton?
        weak var target: AnyObject?
        let action: Selector?
        init(_ button: NSButton) {
            self.button = button
            target = button.target
            action = button.action
        }
    }
    private var buttonRoute: ButtonRoute?
    private var transitionRecovery: Task<Void, Never>?
    private let settled: (NSWindow) -> Void
    private struct ReportedState: Equatable {
        let number: Int
        let style: UInt
        let behavior: UInt
        let level: Int
        let button: ObjectIdentifier?
        let enabled: Bool
        let target: ObjectIdentifier?
        let action: Selector?
    }
    private var lastReportedState: ReportedState?
    private static weak var installedMainMenu: NSMenu?
    private static weak var installedFullscreenItem: NSMenuItem?
    private static var installingMenu = false
    private static let logger = Logger(subsystem: "io.mulg", category: "fullscreen")
    private static let controllers = NSMapTable<NSWindow, NativeGameFullscreen>.weakToWeakObjects()
    private static var nativeActionHookInstalled = false
    private static var zoomHookInstalled = false

    /// Bits of the collection behavior AppKit's `canEnterFullScreenMode` refuses on: it requires
    /// FullScreenPrimary (1<<7) and no FullScreenNone (1<<9), and also bit 15, which is private.
    /// `toggleFullScreen:` is a silent no-op when the window is not eligible.
    private static let privateFullScreenVeto = NSWindow.CollectionBehavior(rawValue: 1 << 15)

    var ownsPresentation: Bool {
        transitioning || window?.styleMask.contains(.fullScreen) == true
    }

    init(window: NSWindow, greenInteraction: @escaping (Bool) -> Void = { _ in },
         settled: @escaping (NSWindow) -> Void) {
        self.window = window
        self.greenInteraction = greenInteraction
        originalBehavior = window.collectionBehavior
        self.settled = settled
        super.init()
        Self.controllers.setObject(self, forKey: window)
        Self.installNativeActionRouter()
        Self.installNativeZoomHook()
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.beginTransition(); self?.report("native-will-transition") }
            })
        }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishTransition(); self?.report("native-did-transition") }
            })
        }
        // UIKit's scene/restoration changes can replace window capability flags after
        // didBecomeKey. Repair only mismatches after its update, without changing actions.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.scheduleRepair() } })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.restore() } })
        // Native window widgets can dispatch actions without our gameplay mouse
        // monitors ever seeing their clicks. Keep AppKit's entire button tracking loop.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window,
                  NSApplication.shared.isActive,
                  (window.isKeyWindow || window.standardWindowButton(.zoomButton)?.window?.isKeyWindow == true),
                  event.charactersIgnoringModifiers?.lowercased() == "f",
                  event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command, .control]
            else { return event }
            if !event.isARepeat { self.toggle() }
            return nil
        }
        // macOS 27's green button (_NSThemeZoomWidget) sends its click straight to the window's
        // private _setNeedsZoom: and never to its target/action or NSApplication.sendAction, so
        // the routes above do not see it, and for a UIKit window the click did nothing. The press
        // itself is taken here instead, in the window or in the fullscreen title bar, and becomes
        // the same request as the menu and Control-Command-F, with or without Option: games use
        // Option (Alt) to free the cursor, so it is often held while the green button is pressed
        // (a real Genshin session logged every green press with Option down). Double-clicking the
        // title bar still zooms; hovering keeps the native tile menu. Only the press is taken: AppKitBridge sees the
        // release and ends its window interaction as before.
        zoomClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = self.window else { return event }
            self.reportTitlebarPress(event)
            guard let button = window.standardWindowButton(.zoomButton), button.isEnabled,
                  let buttonWindow = button.window, event.window === buttonWindow,
                  Self.hitFrame(of: button).contains(event.locationInWindow)
            else { return event }
            self.report("zoom-button-press")
            self.requestFullscreen(button)
            return nil
        }
        configure()
    }

    isolated deinit {
        restoreGreenButton()
        transitionRecovery?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let zoomClickMonitor { NSEvent.removeMonitor(zoomClickMonitor) }
    }

    /// A window updates after nearly every event (a mouse reports at 1000 Hz), but UIKit rewrites the
    /// flags or the button route rarely. Repair once the burst ends, at most four times a second;
    /// transitions and becoming key call `configure()` directly.
    private var repairScheduled = false
    private func scheduleRepair() {
        guard !repairScheduled else { return }
        repairScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
            MainActor.assumeIsolated {
                self?.repairScheduled = false
                self?.configure()
            }
        }
    }

    func configure() {
        guard let window else { return }
        if !ownsPresentation {
            if !window.styleMask.contains(.resizable) { window.styleMask.insert(.resizable) }
            var behavior = window.collectionBehavior
            behavior.subtract([.fullScreenAuxiliary, .fullScreenNone, .fullScreenDisallowsTiling, .auxiliary,
                               .canJoinAllApplications, .canJoinAllSpaces, .moveToActiveSpace, .transient,
                               .stationary, .ignoresCycle, Self.privateFullScreenVeto])
            behavior.formUnion([.primary, .fullScreenPrimary, .fullScreenAllowsTiling, .managed, .participatesInCycle])
            if window.collectionBehavior != behavior { window.collectionBehavior = behavior }
            appliedBehavior = behavior
        }
        routeGreenButton(window)
        if !transitioning { ensureNativeFullscreenMenu() }
        report("configured", changedOnly: true)
    }

    /// The green button, View > Enter/Exit Full Screen and Control-Command-F all end here, like a
    /// native macOS app: AppKit creates the window's own fullscreen Space, and the same request
    /// leaves it again and returns to the desktop. UINSWindow's toggleFullScreen: forwards to
    /// NSWindow's unless UIKit installed an override (it installs none for games), so a normal
    /// call is the right one.
    func toggle() {
        guard let window, !transitioning else { return }
        // AppKit silently ignores the request unless the window is eligible, and fullscreen
        // needs the normal window level (a floating or custom level is restored afterwards).
        configure()
        prepareFullscreenLevel(window)
        // Hold further clicks only briefly: AppKit announces will-enter/exit within a moment, which
        // extends this to the real animation. A refused request must not block the next click.
        beginTransition(grace: .milliseconds(1500))
        report("explicit-request")
        Self.appKitToggleFullScreen(window)
    }

    /// NSWindow's own toggleFullScreen:, past UINSWindow's override hook: UIKit may install a
    /// block there that handles (or drops) the request itself; AppKit's implementation always
    /// creates or leaves the Space, and UIKit still hears about it through its window delegate.
    private static func appKitToggleFullScreen(_ window: NSWindow) {
        let selector = #selector(NSWindow.toggleFullScreen(_:))
        guard let implementation = class_getMethodImplementation(NSWindow.self, selector) else {
            window.toggleFullScreen(nil)
            return
        }
        typealias Toggle = @convention(c) (NSWindow, Selector, AnyObject?) -> Void
        unsafeBitCast(implementation, to: Toggle.self)(window, selector, nil)
    }

    @objc private func requestFullscreen(_ sender: Any?) {
        greenInteraction(true)
        defer { greenInteraction(false) }
        report("native-green-action")
        toggle()
    }

    private func restoreGreenButton() {
        if let saved = buttonRoute, let button = saved.button, button.target === self {
            button.target = saved.target
            button.action = saved.action
        }
        buttonRoute = nil
    }

    private func routeGreenButton(_ window: NSWindow) {
        guard let button = window.standardWindowButton(.zoomButton) else { return }
        let action = #selector(requestFullscreen(_:))
        if buttonRoute?.button !== button { restoreGreenButton() }
        // Re-capture when UIKit replaces its route, rather than keeping a stale target.
        if button.target !== self || button.action != action {
            if button.target !== self { buttonRoute = ButtonRoute(button) }
            button.target = self
            button.action = action
        }
    }

    /// The button's area in window coordinates, a few points wider than drawn so a press on the
    /// glass edge counts.
    private static func hitFrame(of button: NSButton) -> NSRect {
        button.convert(button.bounds, to: nil).insetBy(dx: -4, dy: -4)
    }

    /// Logs a press near the window's top-left corner with the geometry the hit test used, so a
    /// green click that goes unseen can be explained from the log. Presses elsewhere cost nothing.
    private func reportTitlebarPress(_ event: NSEvent) {
        guard let window, let eventWindow = event.window,
              eventWindow === window || window.childWindows?.contains(eventWindow) == true
                  || NSStringFromClass(type(of: eventWindow)).contains("Title") else { return }
        let point = event.locationInWindow
        guard point.x < 140, eventWindow.frame.height - point.y < 48 else { return }
        let button = window.standardWindowButton(.zoomButton)
        let frame = button.map { Self.hitFrame(of: $0) }
        Self.logger.notice("""
            Mulg fullscreen titlebar-press: eventWindow=\(NSStringFromClass(type(of: eventWindow)), privacy: .public) \
            same=\(eventWindow === window, privacy: .public) point=\(NSStringFromPoint(point), privacy: .public) \
            zoomFrame=\(frame.map(NSStringFromRect) ?? "none", privacy: .public) \
            hit=\(frame?.contains(point) == true, privacy: .public) hidden=\(button?.isHidden == true, privacy: .public) \
            enabled=\(button?.isEnabled == true, privacy: .public) option=\(event.modifierFlags.contains(.option), privacy: .public)
            """)
    }

    /// macOS 27's green button (_NSThemeZoomWidget) calls the window's own `_setNeedsZoom:` and
    /// nothing else: not its target/action, and no hook above it sees the click. NSWindow
    /// implements that method (UIKit's window class inherits it), and it decides between zoom and
    /// fullscreen itself. For a window this controller manages the request becomes the same
    /// Space transition as the menu and Control-Command-F, also with Option held (the game's
    /// cursor key); every other window gets the original implementation.
    private static func installNativeZoomHook() {
        guard !zoomHookInstalled else { return }
        let selector = NSSelectorFromString("_setNeedsZoom:")
        guard let original = class_getMethodImplementation(NSWindow.self, selector),
              class_getInstanceMethod(NSWindow.self, selector) != nil else {
            logger.notice("Mulg fullscreen zoom hook unavailable: NSWindow has no _setNeedsZoom:")
            return
        }
        typealias SetNeedsZoom = @convention(c) (NSWindow, Selector, AnyObject?) -> Void
        let block: @convention(block) (NSWindow, AnyObject?) -> Void = { window, sender in
            MainActor.assumeIsolated {
                if let controller = controllers.object(forKey: window) {
                    controller.report("native-zoom-request")
                    controller.requestFullscreen(nil)
                    return
                }
                unsafeBitCast(original, to: SetNeedsZoom.self)(window, selector, sender)
            }
        }
        let replacement = imp_implementationWithBlock(block)
        typealias Install = @convention(c) (UnsafePointer<CChar>, AnyClass, Selector, IMP,
            UnsafeMutablePointer<IMP?>?, UnsafePointer<CChar>, NSArray) -> Int
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "mulg_swizzle_checked_owned") else {
            imp_removeBlock(replacement)
            logger.notice("Mulg fullscreen zoom hook unavailable; using button route")
            return
        }
        let install = unsafeBitCast(symbol, to: Install.self)
        zoomHookInstalled = "v".withCString {
            install("bridge", NSWindow.self, selector, replacement, nil, $0, ["@"] as NSArray)
        } == 0
        if !zoomHookInstalled { imp_removeBlock(replacement) }
        logger.notice("Mulg fullscreen zoom hook installed=\(zoomHookInstalled, privacy: .public)")
    }

    /// A checked public dispatch hook also covers a UIKit route rewritten between window
    /// updates. Only a registered game's actual standard green button is intercepted.
    /// Other controls, windows and menus call the original implementation.
    private static func installNativeActionRouter() {
        guard !nativeActionHookInstalled, let cls = object_getClass(NSApplication.shared) else { return }
        let selector = #selector(NSApplication.sendAction(_:to:from:))
        guard let method = class_getInstanceMethod(cls, selector),
              method_getNumberOfArguments(method) == 5 else { return }
        let resultType = method_copyReturnType(method)
        defer { free(resultType) }
        let encoding = String(cString: resultType)
        guard ["B", "c"].contains(encoding) else { return }
        let original = method_getImplementation(method)
        typealias SendAction = @convention(c) (NSApplication, Selector, Selector, AnyObject?, AnyObject?) -> Bool
        let block: @convention(block) (NSApplication, Selector, AnyObject?, AnyObject?) -> Bool = { app, action, target, sender in
            MainActor.assumeIsolated {
                if let button = sender as? NSButton,
                   let controller = controllers.objectEnumerator()?.allObjects.compactMap({ $0 as? NativeGameFullscreen })
                    .first(where: { $0.window?.standardWindowButton(.zoomButton) === button }),
                   action == button.action || action == controller.buttonRoute?.action {
                    controller.requestFullscreen(button)
                    return true
                }
                return unsafeBitCast(original, to: SendAction.self)(app, selector, action, target, sender)
            }
        }
        let replacement = imp_implementationWithBlock(block)
        typealias Install = @convention(c) (UnsafePointer<CChar>, AnyClass, Selector, IMP,
            UnsafeMutablePointer<IMP?>?, UnsafePointer<CChar>, NSArray) -> Int
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "mulg_swizzle_checked_owned") else {
            imp_removeBlock(replacement)
            logger.notice("Mulg fullscreen native action router unavailable; using button route")
            return
        }
        let install = unsafeBitCast(symbol, to: Install.self)
        nativeActionHookInstalled = encoding.withCString {
            install("bridge", cls, selector, replacement, nil, $0, [":", "@", "@"] as NSArray)
        } == 0
        if !nativeActionHookInstalled { imp_removeBlock(replacement) }
        logger.notice("Mulg fullscreen native action router installed=\(nativeActionHookInstalled, privacy: .public)")
    }

    /// Supply a missing View command through the same Space transition as a green click.
    /// Existing game menu commands remain intact; the shortcut is routed above.
    private func ensureNativeFullscreenMenu() {
        guard !Self.installingMenu, let main = NSApplication.shared.mainMenu else { return }
        Self.installingMenu = true
        defer { Self.installingMenu = false }
        let action = #selector(NSWindow.toggleFullScreen(_:))
        func isFullscreenCommand(_ item: NSMenuItem) -> Bool {
            item.action == action || (item.keyEquivalent.lowercased() == "f" &&
                item.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift]) == [.command, .control])
        }
        func isAttached(_ item: NSMenuItem) -> Bool {
            var menu = item.menu
            while let current = menu {
                if current === main { return true }
                menu = current.supermenu
            }
            return false
        }
        if Self.installedMainMenu === main, let item = Self.installedFullscreenItem, isAttached(item) {
            if item.identifier?.rawValue == "io.mulg.nativeFullscreen" {
                let command = #selector(requestFullscreen(_:))
                if item.action != command { item.action = command }
                if item.target !== self { item.target = self }
                let title = window?.styleMask.contains(.fullScreen) == true ? "Exit Full Screen" : "Enter Full Screen"
                if item.title != title { item.title = title }
                return
            }
            if isFullscreenCommand(item) { return }
        }
        func existingCommand(in menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                // Preserve a game's existing shortcut or UIKit fullscreen command.
                if isFullscreenCommand(item) { return item }
                if let submenu = item.submenu, let existing = existingCommand(in: submenu) { return existing }
            }
            return nil
        }
        if let existing = existingCommand(in: main) {
            Self.installedMainMenu = main
            Self.installedFullscreenItem = existing
            return
        }
        let viewItem = main.items.first { item in
            item.title == "View" || item.identifier?.rawValue.lowercased().hasSuffix(".view") == true ||
                item.submenu?.identifier?.rawValue.lowercased().hasSuffix(".view") == true
        }
        let view: NSMenu
        if let existing = viewItem?.submenu { view = existing }
        else {
            view = NSMenu(title: "View")
            let item = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier("io.mulg.nativeView")
            item.submenu = view
            main.insertItem(item, at: min(2, main.items.count))
        }
        if !view.items.isEmpty { view.addItem(.separator()) }
        let item = NSMenuItem(title: "Enter Full Screen", action: #selector(requestFullscreen(_:)), keyEquivalent: "f")
        item.target = self
        item.keyEquivalentModifierMask = [.command, .control]
        item.identifier = NSUserInterfaceItemIdentifier("io.mulg.nativeFullscreen")
        view.addItem(item)
        Self.installedMainMenu = main
        Self.installedFullscreenItem = item
    }

    private func prepareFullscreenLevel(_ window: NSWindow) {
        if windowedLevel == nil { windowedLevel = window.level }
        if window.level != .normal { window.level = .normal }
    }

    private func restoreWindowedLevel(_ window: NSWindow) {
        if let windowedLevel, window.level == .normal { window.level = windowedLevel }
        windowedLevel = nil
    }

    private func beginTransition(grace: Duration = .seconds(5)) {
        guard let window else { return }
        transitioning = true
        prepareFullscreenLevel(window)
        transitionRecovery?.cancel()
        // Native failure callbacks belong to UIKit's delegate. Release our guard after
        // a refused/interrupted transition too, without replacing that delegate.
        transitionRecovery = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            self?.report("completion-not-received")
            self?.finishTransition()
        }
    }

    private func finishTransition() {
        transitionRecovery?.cancel()
        transitionRecovery = nil
        transitioning = false
        guard let window else { return }
        if !window.styleMask.contains(.fullScreen) { restoreWindowedLevel(window) }
        configure()
        settled(window)
    }

    /// Only changed native state and actual actions/transitions are logged. No per-frame
    /// writes or window titles/game content are recorded.
    private func report(_ event: String, changedOnly: Bool = false) {
        guard let window else { return }
        let button = window.standardWindowButton(.zoomButton)
        let fingerprint = ReportedState(number: window.windowNumber, style: window.styleMask.rawValue,
            behavior: window.collectionBehavior.rawValue, level: window.level.rawValue,
            button: button.map(ObjectIdentifier.init), enabled: button?.isEnabled == true,
            target: button?.target.map(ObjectIdentifier.init), action: button?.action)
        guard !changedOnly || fingerprint != lastReportedState else { return }
        lastReportedState = fingerprint
        let target = button?.target.map { NSStringFromClass(type(of: $0)) } ?? "responder-chain"
        let action = button?.action.map(NSStringFromSelector) ?? "none"
        let state = "window=\(window.windowNumber) class=\(NSStringFromClass(type(of: window))) " +
            "style=\(window.styleMask.rawValue) behavior=\(window.collectionBehavior.rawValue) " +
            "fullscreen=\(window.styleMask.contains(.fullScreen)) level=\(window.level.rawValue) " +
            "buttonEnabled=\(button?.isEnabled == true) target=\(target) action=\(action) " +
            "canEnter=\(Self.appKitAllowsFullScreen(window))"
        Self.logger.notice("Mulg fullscreen \(event, privacy: .public): \(state, privacy: .public)")
    }

    /// AppKit's own eligibility test (a private getter, read only for the log).
    private static func appKitAllowsFullScreen(_ window: NSWindow) -> String {
        let selector = NSSelectorFromString("canEnterFullScreenMode")
        guard window.responds(to: selector), let value = window.value(forKey: "canEnterFullScreenMode") as? Bool
        else { return "unknown" }
        return value ? "yes" : "NO"
    }

    func restore() {
        restoreGreenButton()
        transitionRecovery?.cancel()
        transitionRecovery = nil
        if let window, !ownsPresentation {
            restoreWindowedLevel(window)
            if window.collectionBehavior == appliedBehavior { window.collectionBehavior = originalBehavior }
        }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        if let zoomClickMonitor { NSEvent.removeMonitor(zoomClickMonitor) }
        zoomClickMonitor = nil
        if let item = Self.installedFullscreenItem, item.target === self {
            item.target = nil
            item.action = #selector(NSWindow.toggleFullScreen(_:))
        }
        if let window, Self.controllers.object(forKey: window) === self { Self.controllers.removeObject(forKey: window) }
        window = nil
    }
}
#endif
