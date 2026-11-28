#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import CoreGraphics
import Foundation
import CryptoKit
import Security
import IOKit.ps
import Metal
import MulgBridge
import QuartzCore
import ObjectiveC
import os

/// The AppKit side of the bridge, built as a macOS bundle and loaded into the game.
/// Ported from upstream's MulgAppKitPlugin (Runtime/MulgAppKitPlugin.swift) with these changes:
/// - window preferences come from the runtime instead of a hard-coded `/Users/<name>`
///   settings path (PLAN.md §12 #3);
/// - no force unwraps of `NSScreen.main` or the first window (§12 #15);
/// - new: refresh rate, HDR headroom, power source, visibility, full screen, vsync,
///   modifier releases and trackpad gestures.
@MainActor
@objc(MulgAppKitBridge)
public final class AppKitBridge: NSObject, MacBridge {
    private let audioOutput = AudioOutputController()
    private let hudCapture = GameHUDCapture()
    private let gameCommandMenu = GameCommandMenu()
    private var observingGameMenu = false

    public func installGameMenu(_ commands: [[String: Any]], title: String, perform: @escaping (String) -> Void) {
        gameCommandMenu.update(commands, title: title, perform: perform, in: NSApplication.shared.mainMenu)
        guard !observingGameMenu else { return }
        observingGameMenu = true
        // UIKit can publish/rebuild its native menu after the first scene's activation.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.gameCommandMenu.reconcile(in: NSApplication.shared.mainMenu) }
        })
    }

    public func captureGameHUD(in rect: CGRect, requestPermission: Bool,
                               completion: @escaping (Data?, Int, Int, String?) -> Void) {
        hudCapture.capture(window: gameWindow, rect: rect, requestPermission: requestPermission, completion: completion)
    }

    public func configureAudioOutput(sampleRate: Double, bitDepth: Int, protect: Bool, report: @escaping (NSDictionary) -> Void) {
        audioOutput.configure(rate: sampleRate, depth: bitDepth, protect: protect, report: report)
    }

    public func reassertAudioOutput() { audioOutput.reassert() }
    public func stopAudioOutput(restore: Bool) { audioOutput.stop(restore: restore) }

    nonisolated public func credentialPasswordEnvelope(_ data: Data, accessibility: String, opening: Bool,
        failure: AutoreleasingUnsafeMutablePointer<NSError?>?) -> Data? {
        failure?.pointee = nil
        do { return try ProtectedPasswordEnvelope.transform(data, accessibility: accessibility, opening: opening) }
        catch { failure?.pointee = error as NSError; return nil }
    }

    // Migration only (2026-10-10): database keys are sealed in Mulg's own files now (SealedSecret, opened by the
    // integrations module). These read and then delete the item an older Mulg kept in the login keychain, on
    // the one launch that runs without the keychain wall. Nothing here creates a Keychain item.
    nonisolated private static let legacyCredentialService = "io.mulg.credentials.v1"

    nonisolated public func credentialEncryptionKey(forDatabasePath path: String, createIfMissing: Bool) -> Data? {
        // ContainerPaths names the database after its bundle ID; moving the home folder keeps that identity.
        let account = URL(fileURLWithPath: path).lastPathComponent, service = Self.legacyCredentialService
        var length: UInt32 = 0
        var bytes: UnsafeMutableRawPointer?
        let status = service.withCString { serviceBytes in account.withCString { accountBytes in
            SecKeychainFindGenericPassword(nil, UInt32(service.utf8.count), serviceBytes,
                                          UInt32(account.utf8.count), accountBytes, &length, &bytes, nil)
        } }
        guard status == errSecSuccess, let bytes else { return nil }
        defer { SecKeychainItemFreeContent(nil, bytes) }
        return length == 32 ? Data(bytes: bytes, count: Int(length)) : nil
    }

    nonisolated public func removeLegacyCredentialKey(forDatabasePath path: String) {
        let account = URL(fileURLWithPath: path).lastPathComponent, service = Self.legacyCredentialService
        var item: SecKeychainItem?
        let status = service.withCString { serviceBytes in account.withCString { accountBytes in
            SecKeychainFindGenericPassword(nil, UInt32(service.utf8.count), serviceBytes,
                                          UInt32(account.utf8.count), accountBytes, nil, nil, &item)
        } }
        if status == errSecSuccess, let item { SecKeychainItemDelete(item) }
    }

    /// NSCursor counts hides, so a second hide would need a second unhide. The router and a
    /// dragged button both hide and show the cursor; a state keeps them from unbalancing it.
    private var cursorHidden = false
    private var pointerCursorHiddenRequested = false
    private var pointerCursorHidden = false
    private var cursorCaptureRequested = false
    private weak var cursorLockWindow: NSWindow?
    private var cursorLockPoint: CGPoint?
    private var nextCursorRepair: UInt64 = 0
    /// Window chrome owns a complete native drag, even if Option is released mid-drag.
    private var nativeWindowButtons: Set<Int> = []
    var isWindowInteractionActive: Bool { !nativeWindowButtons.isEmpty }
    private var lastWindowFocus = false
    private var observers: [NSObjectProtocol] = []
    private var eventMonitors: [Any] = []
    /// Mouse buttons whose press went to the game.
    private var pressedButtons: Set<Int> = []
    private var pressedKeys: Set<UInt16> = []
    private var pressedModifiers: Set<UInt16> = []
    private var consumedKeys: Set<UInt16> = []
    private var consumedButtons: Set<Int> = []
    private var consumedModifiers: Set<UInt16> = []
    private var powerTimer: Timer?
    /// IOKit's power-source change notification on the main run loop.
    // Written once on main; deinit only invalidates it.
    nonisolated(unsafe) private var powerSource: CFRunLoopSource?
    private var lastBatteryState: Bool?
    private var preferences = WindowPreferences()

    private struct WindowPreferences {
        var hideTitleBar = false
        var floating = false
        var aspectRatio: NSSize?
        var rememberFrame = false
    }
    private static let frameName = "Mulg game window"

    @MainActor private final class WindowState {
        var fullscreen: NativeGameFullscreen?
        var titleBar: (transparent: Bool, visibility: NSWindow.TitleVisibility, toolbar: NSToolbar?,
                       title: String, fullSize: Bool)?
        var level: NSWindow.Level?
        var aspect: NSSize?
        var pointerInput: (backgroundDrag: Bool, mouseMoved: Bool)?
        var frameRemembered = false

        func preparePointerInput(_ window: NSWindow) {
            if pointerInput == nil {
                pointerInput = (window.isMovableByWindowBackground, window.acceptsMouseMovedEvents)
            }
            // Render views are not AppKit controls. Let their content clicks reach UIKit
            // instead of making the whole render surface a native window-drag handle.
            window.isMovableByWindowBackground = false
            window.acceptsMouseMovedEvents = true
        }

        func restoreTitleBar(_ window: NSWindow) {
            guard let original = titleBar else { return }
            window.titlebarAppearsTransparent = original.transparent
            window.titleVisibility = original.visibility
            window.toolbar = original.toolbar
            window.title = original.title
            if original.fullSize { window.styleMask.insert(.fullSizeContentView) }
            else { window.styleMask.remove(.fullSizeContentView) }
            titleBar = nil
        }
        func restore(_ window: NSWindow) {
            fullscreen?.restore()
            fullscreen = nil
            restoreTitleBar(window)
            if let level { window.level = level; self.level = nil }
            if let aspect { window.contentAspectRatio = aspect; self.aspect = nil }
            if let pointerInput {
                if !window.isMovableByWindowBackground {
                    window.isMovableByWindowBackground = pointerInput.backgroundDrag
                }
                if window.acceptsMouseMovedEvents {
                    window.acceptsMouseMovedEvents = pointerInput.mouseMoved
                }
                self.pointerInput = nil
            }
        }
    }
    private let windowStates = NSMapTable<NSWindow, WindowState>.weakToStrongObjects()

    deinit {
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
    }

    public required override init() {
        super.init()
        NSWindow.allowsAutomaticWindowTabbing = true
        // Registered first, so the handlers below already see the new game window.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didBecomeMainNotification, NSWindow.willCloseNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cachedGameWindow = nil }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] notification in
            // Delivered on the main queue; the object is only read there.
            nonisolated(unsafe) let object = notification.object
            MainActor.assumeIsolated {
                guard let self, let window = object as? NSWindow else { return }
                self.closingWindows.remove(window)
                self.cachedGameWindow = nil
                guard window == self.gameWindow else { return }
                self.apply(to: window)
            }
        })
    }

    /// UIKit scene windows can be key without being main. Sheets and panels are not games.
    private weak var selectedGameWindow: NSWindow? {
        didSet { cachedGameWindow = nil }
    }
    private var closingWindows = NSHashTable<NSWindow>.weakObjects()
    private var gameWindows: [NSWindow] {
        NSApplication.shared.windows.filter {
            !closingWindows.contains($0) && !($0 is NSPanel) && $0.sheetParent == nil && $0.contentView != nil
                && ($0.canBecomeMain || $0.canBecomeKey || $0.isMiniaturized || $0 === selectedGameWindow)
        }
    }
    public func bindGameLayer(_ layer: CALayer) {
        let previous = gameWindow
        var roots: Set<ObjectIdentifier> = []
        var ancestor: CALayer? = layer
        while let current = ancestor { roots.insert(ObjectIdentifier(current)); ancestor = current.superlayer }
        selectedGameWindow = NSApplication.shared.windows.first { window in
            window.contentView?.layer.map { roots.contains(ObjectIdentifier($0)) } == true
        }
        if previous !== gameWindow {
            if let previous { windowStates.object(forKey: previous)?.restore(previous) }
            notifyDisplayChanged()
            notifyFocusChanged()
        }
        if let gameWindow { apply(to: gameWindow) }
    }
    private func notifyDisplayChanged() {
        if cursorHidden {
            cursorLockWindow = nil
            updateCursorCapture()
        }
        let rate = displayMaximumRefreshRate
        displayHandlers.forEach { $0(rate) }
    }
    /// Asked for on every mouse event, so the window list is filtered at most every 250 ms, and at
    /// once after a window changes focus, closes, minimises or is chosen as the game's.
    private var gameWindow: NSWindow? {
        let now = DispatchTime.now().uptimeNanoseconds
        if let cachedGameWindow, now &- cachedGameWindowTime < 250_000_000 { return cachedGameWindow }
        let windows = gameWindows
        let window = selectedGameWindow.flatMap { windows.contains($0) ? $0 : nil }
            ?? windows.first(where: \.isKeyWindow) ?? windows.first
        cachedGameWindow = window
        cachedGameWindowTime = now
        return window
    }
    private weak var cachedGameWindow: NSWindow?
    private var cachedGameWindowTime: UInt64 = 0

    // MARK: Screens and window

    public var screenCount: Int { NSScreen.screens.count }

    public var mainScreenFrame: CGRect {
        (NSScreen.main ?? NSScreen.screens.first)?.frame ?? .zero
    }

    public var isMainScreenEqualToFirst: Bool {
        NSScreen.main == NSScreen.screens.first
    }

    public var windowFrame: CGRect { gameWindow?.frame ?? .zero }

    public var isFullscreen: Bool {
        gameWindow?.styleMask.contains(.fullScreen) ?? false
    }

    /// A game window that is the key window of the active app is on screen whatever its occlusion
    /// state still says: after a Space switch or ⌘Tab back the state can lag behind, and the game
    /// stayed at the hidden-window frame rate (5 FPS), frozen to the player.
    public var isWindowVisible: Bool {
        // Only on the active Space: after a swipe to an empty desktop the app can stay active with
        // the game still key, and the game would then draw at full speed out of view.
        if NSApplication.shared.isActive, let key = NSApplication.shared.keyWindow, gameWindows.contains(key),
           !key.isMiniaturized, key.isOnActiveSpace { return true }
        return gameWindows.contains { !$0.isMiniaturized && $0.occlusionState.contains(.visible) }
    }

    private var gameScreen: NSScreen? {
        gameWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    public var displayMaximumRefreshRate: Int {
        gameScreen?.maximumFramesPerSecond ?? 60
    }

    public var displayHasVariableRefresh: Bool {
        gameScreen.map { $0.maximumRefreshInterval > $0.minimumRefreshInterval } ?? false
    }

    public var displayEDRHeadroom: CGFloat {
        gameScreen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
    }

    public func toggleFullScreen() {
        guard let gameWindow else { return }
        apply(to: gameWindow)
        windowStates.object(forKey: gameWindow)?.fullscreen?.toggle()
    }

    public func setMenuBarVisible(_ visible: Bool) {
        NSMenu.setMenuBarVisible(visible)
    }

    public func applyWindowPreferences(hideTitleBar: Bool, floating: Bool, aspectWidth: Int, aspectHeight: Int) {
        preferences.hideTitleBar = hideTitleBar
        preferences.floating = floating
        preferences.aspectRatio = aspectWidth > 0 && aspectHeight > 0
            ? NSSize(width: aspectWidth, height: aspectHeight) : nil
        if let gameWindow { apply(to: gameWindow) }
    }

    public func rememberWindowFrame(_ remember: Bool) {
        preferences.rememberFrame = remember
        if let gameWindow { apply(to: gameWindow) }
    }

    private func apply(to window: NSWindow) {
        let state = windowStates.object(forKey: window) ?? WindowState()
        windowStates.setObject(state, forKey: window)
        if state.fullscreen == nil {
            state.fullscreen = NativeGameFullscreen(window: window, greenInteraction: { [weak self] pressed in
                if pressed { self?.beginWindowInteraction(button: 0) }
                else { self?.endWindowInteraction(button: 0) }
            }) { [weak self] window in
                guard let self, window === self.gameWindow else { return }
                self.apply(to: window)
                self.notifyDisplayChanged()
            }
        }
        state.fullscreen?.configure()
        // Input belongs to the content even during fullscreen transitions. Only geometry
        // preferences below need to wait for AppKit to finish changing presentation.
        state.preparePointerInput(window)
        // AppKit owns geometry, chrome and level while entering, in, or leaving its
        // fullscreen Space. Saved preferences are reapplied after native exit.
        guard state.fullscreen?.ownsPresentation != true else { return }
        // Restored once per window, before the aspect fit below corrects its shape; AppKit then
        // keeps the saved frame current as the player moves and resizes the window.
        if preferences.rememberFrame != state.frameRemembered, !window.styleMask.contains(.fullScreen) {
            state.frameRemembered = preferences.rememberFrame
            if preferences.rememberFrame {
                window.setFrameUsingName(Self.frameName)
                _ = window.setFrameAutosaveName(Self.frameName)
            } else {
                _ = window.setFrameAutosaveName("")
            }
        }
        window.isMovable = true
        if preferences.hideTitleBar {
            if state.titleBar == nil {
                state.titleBar = (window.titlebarAppearsTransparent, window.titleVisibility,
                                  window.toolbar, window.title, window.styleMask.contains(.fullSizeContentView))
            }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.toolbar = nil
            window.title = ""
        } else {
            state.restoreTitleBar(window)
        }
        if preferences.floating {
            if state.level == nil { state.level = window.level }
            window.level = .floating
        } else if let level = state.level {
            window.level = level
            state.level = nil
        }
        // Full screen keeps the same shape: AppKit centers the content and fills the rest black.
        Self.fullScreenShapes.setObject(preferences.aspectRatio.map { NSValue(size: $0) }, forKey: window)
        if preferences.aspectRatio != nil { Self.installFullScreenFit(for: window) }
        if let aspectRatio = preferences.aspectRatio {
            if state.aspect == nil { state.aspect = window.contentAspectRatio }
            window.contentAspectRatio = aspectRatio
            // contentAspectRatio constrains future resizing, but leaves an existing 4:3
            // window unchanged. Fit the current content into the new calibrated shape.
            if !window.styleMask.contains(.fullScreen), let content = window.contentView,
               content.bounds.width > 0, content.bounds.height > 0 {
                let ratio = aspectRatio.width / aspectRatio.height
                if abs(content.bounds.width / content.bounds.height - ratio) > 0.01 {
                    let width = min(content.bounds.width, content.bounds.height * ratio)
                    window.setContentSize(NSSize(width: width, height: width / ratio))
                }
            }
        } else if let aspect = state.aspect {
            window.contentAspectRatio = aspect
            state.aspect = nil
        }
    }

    // MARK: Power

    public var isOnBatteryPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else {
            return false
        }
        return (type as String) == kIOPMBatteryPowerKey
    }

    // MARK: Observation

    // Handlers are stored on the bridge (main actor) and the system callbacks capture only
    // `self`, because notification and timer callbacks are @Sendable in Swift 6.
    private var displayHandlers: [(Int) -> Void] = []
    private var visibilityHandlers: [(Bool) -> Void] = []
    private var powerHandlers: [(Bool) -> Void] = []
    private var closingHandlers: [() -> Void] = []
    private var focusHandlers: [(Bool, Bool) -> Void] = []
    private var inUseHandlers: [(Bool) -> Void] = []
    private var lastInUse: Bool?
    private var resizeHandlers: [(Bool) -> Void] = []
    // Finish the window that began the transaction even if viewport selection/key focus
    // changes while it is being dragged. Closing that window also releases consumers.
    private let resizingWindows = NSHashTable<NSWindow>.weakObjects()
    /// Counts resize starts, so a full-screen timeout never ends a later resize.
    private var resizeTransaction = 0

    public func observeDisplayChanges(_ handler: @escaping (Int) -> Void) {
        displayHandlers.append(handler)
        guard displayHandlers.count == 1 else { return }
        for name in [NSWindow.didChangeScreenNotification, NSApplication.didChangeScreenParametersNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.notifyDisplayChanged()
                }
            })
        }
    }

    public func observeWindowVisibility(_ handler: @escaping (Bool) -> Void) {
        visibilityHandlers.append(handler)
        guard visibilityHandlers.count == 1 else { return }
        // Occlusion alone missed returns to a full-screen Space; activation, key and Space changes are
        // checked too, at once and again when AppKit has settled.
        let recheck: @MainActor () -> Void = { [weak self] in
            self?.reportVisibility()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { self?.reportVisibility() } }
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { recheck() }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { recheck() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] notification in
            // Delivered on the main queue; the object is only read there.
            nonisolated(unsafe) let object = notification.object
            MainActor.assumeIsolated {
                guard let self, let window = object as? NSWindow, self.gameWindows.contains(window) else { return }
                self.reportVisibility(force: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    MainActor.assumeIsolated { self?.reportVisibility() }
                }
            }
        })
    }

    private var reportedVisible: Bool?

    /// Tells the visibility handlers when the game window's visibility changed (and on every
    /// occlusion change, as before, when `force`).
    private func reportVisibility(force: Bool = false) {
        let visible = isWindowVisible
        guard force || visible != reportedVisible else { return }
        if visible != reportedVisible {
            Self.lifecycleLogger.notice("Game window \(visible ? "visible" : "hidden", privacy: .public)")
        }
        reportedVisible = visible
        visibilityHandlers.forEach { $0(visible) }
    }

    public func observeLiveResize(_ handler: @escaping (Bool) -> Void) {
        resizeHandlers.append(handler)
        guard resizeHandlers.count == 1 else { return }
        // A full-screen switch is a resize too: AppKit animates the window frame for about half a second
        // without live-resize notifications, and every frame of it used to resize the game's renderer
        // (the lag when entering or leaving full screen). It now ends like a drag, once, at the final size.
        let starts: Set<NSNotification.Name> = [NSWindow.willStartLiveResizeNotification,
                                                NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification]
        for name in [NSWindow.willStartLiveResizeNotification, NSWindow.didEndLiveResizeNotification,
                     NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
                     NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification,
                     NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                nonisolated(unsafe) let object = notification.object
                let name = notification.name
                MainActor.assumeIsolated {
                    guard let self, let window = object as? NSWindow else { return }
                    if starts.contains(name) {
                        guard self.gameWindows.contains(window), !self.resizingWindows.contains(window) else { return }
                        if name == NSWindow.willStartLiveResizeNotification,
                           window === self.gameWindow, !window.styleMask.contains(.fullScreen),
                           let state = self.windowStates.object(forKey: window),
                           state.fullscreen?.ownsPresentation != true,
                           let aspect = self.preferences.aspectRatio {
                            // UIKit can reset native size constraints after a scene update.
                            // Reassert only the content ratio before a drag, without resizing
                            // the render surface or interfering with a fullscreen transition.
                            if state.aspect == nil { state.aspect = window.contentAspectRatio }
                            window.contentAspectRatio = aspect
                        }
                        let first = self.resizingWindows.allObjects.isEmpty
                        self.resizingWindows.add(window)
                        if first { self.resizeHandlers.forEach { $0(true) } }
                        if name != NSWindow.willStartLiveResizeNotification {
                            // A failed switch sends no "did" notification: never stay in a resize.
                            self.resizeTransaction &+= 1
                            let transaction = self.resizeTransaction
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak window] in
                                MainActor.assumeIsolated {
                                    guard let self, let window, self.resizeTransaction == transaction,
                                          self.resizingWindows.contains(window),
                                          !window.inLiveResize else { return }
                                    self.resizingWindows.remove(window)
                                    if self.resizingWindows.allObjects.isEmpty { self.resizeHandlers.forEach { $0(false) } }
                                }
                            }
                        }
                    } else {
                        guard self.resizingWindows.contains(window) else { return }
                        self.resizingWindows.remove(window)
                        if self.resizingWindows.allObjects.isEmpty { self.resizeHandlers.forEach { $0(false) } }
                    }
                }
            })
        }
    }

    public func observePowerSource(_ handler: @escaping (Bool) -> Void) {
        powerHandlers.append(handler)
        guard powerSource == nil, powerTimer == nil else { return }
        lastBatteryState = isOnBatteryPower
        // IOKit calls back on the main run loop as soon as the power source changes, so battery
        // saver switches at once and nothing runs in between. The bridge lives for the whole
        // process; deinit invalidates the source anyway.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let bridge = Unmanaged<AppKitBridge>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { bridge.powerSourceChanged() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = source
            return
        }
        // No notification source: poll every 5 seconds instead.
        powerTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.powerSourceChanged() }
        }
    }

    private func powerSourceChanged() {
        let onBattery = isOnBatteryPower
        guard onBattery != lastBatteryState else { return }
        lastBatteryState = onBattery
        powerHandlers.forEach { $0(onBattery) }
    }

    public func observeWindowFocus(_ handler: @escaping (Bool, Bool) -> Void) {
        focusHandlers.append(handler)
        guard focusHandlers.count == 1 else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.notifyFocusChanged()
                }
            })
        }
    }

    public func observeGameInUse(_ handler: @escaping (Bool) -> Void) {
        inUseHandlers.append(handler)
        if inUseHandlers.count == 1 {
            // Visibility the focus notifications miss: covered by another window, another Space, another
            // app's full screen.
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.notifyInUseChanged() }
            })
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.notifyInUseChanged() }
            })
            if focusHandlers.isEmpty { observeWindowFocus { _, _ in } }
        }
        handler(gameInUse)
    }

    /// In-use only: occlusion and Space changes fire for every window (tooltips too), so they must not
    /// re-run the focus pipeline (lifecycle, cursor capture, window buttons).
    private func notifyInUseChanged() {
        guard !inUseHandlers.isEmpty else { return }
        let inUse = gameInUse
        guard inUse != lastInUse else { return }
        lastInUse = inUse
        inUseHandlers.forEach { $0(inUse) }
    }

    /// See `MacBridge.observeGameInUse`.
    private var gameInUse: Bool {
        let app = NSApplication.shared
        return Self.inUse(active: app.isActive, hidden: app.isHidden,
                          windows: gameWindows.map { ($0.isMiniaturized, $0.isVisible, $0.occlusionState.contains(.visible)) })
    }

    nonisolated static func inUse(active: Bool, hidden: Bool, windows: [(minimised: Bool, visible: Bool, unoccluded: Bool)]) -> Bool {
        active && !hidden && windows.contains { !$0.minimised && $0.visible && $0.unoccluded }
    }

    private func notifyFocusChanged() {
        let app = NSApplication.shared
        let onScreen = !app.isHidden && gameWindows.contains { !$0.isMiniaturized && $0.isVisible }
        let focused = onScreen && app.isActive && gameWindow?.isKeyWindow == true
        if !focused && lastWindowFocus { nativeWindowButtons.removeAll() }
        lastWindowFocus = focused
        updateCursorCapture()
        focusHandlers.forEach { $0(focused, onScreen) }
        notifyInUseChanged()
    }

    public func observeWindowClosing(_ handler: @escaping () -> Void) {
        closingHandlers.append(handler)
        guard closingHandlers.count == 1 else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] notification in
            // Delivered on the main queue; the object is only read there.
            nonisolated(unsafe) let object = notification.object
            MainActor.assumeIsolated {
                // Only the game window: closing a panel or an alert must not quit the game.
                guard let self, let window = object as? NSWindow, self.gameWindows.contains(window) else { return }
                self.closingWindows.add(window)
                self.cachedGameWindow = nil
                if self.selectedGameWindow === window { self.selectedGameWindow = nil }
                if self.gameWindows.isEmpty { self.closingHandlers.forEach { $0() } }
            }
        })
    }

    private static weak var quitBridge: AppKitBridge?
    private var terminationHandler: (() -> Void)?
    private var deferredTerminationHandler: (() -> Void)?
    private var deferredTerminationReported = false
    private var quitPending = false
    private var shutdownFinished = false

    private static func installQuitHook(_ cls: AnyClass, selector: Selector, replacement: IMP,
                                        result: String, arguments: [String]) -> Bool {
        // The runtime already owns this registry. Resolve it rather than linking a second
        // copy of engine hooks (and their interposes) into the native bridge bundle.
        typealias Install = @convention(c) (UnsafePointer<CChar>, AnyClass, Selector, IMP,
            UnsafeMutablePointer<IMP?>?, UnsafePointer<CChar>, NSArray) -> Int
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "mulg_swizzle_checked_owned") else {
            imp_removeBlock(replacement)
            return false
        }
        let install = unsafeBitCast(symbol, to: Install.self)
        let installed = result.withCString { install("bridge", cls, selector, replacement, nil, $0, arguments as NSArray) } == 0
        if !installed { imp_removeBlock(replacement) }
        return installed
    }

    // MARK: Quit shortcut guard

    private var quitGuard = QuitShortcutGuard()
    private var quitGuardEnabled = false
    private var quitGuardWarning: (() -> Void)?
    private var quitGuardMonitor: Any?

    public func guardQuitShortcut(_ enabled: Bool, warn: @escaping () -> Void) {
        quitGuardEnabled = enabled
        quitGuardWarning = warn
        guard quitGuardMonitor == nil else { return }
        quitGuardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.quitGuardEnabled,
                  event.charactersIgnoringModifiers?.lowercased() == "q", // the Quit key in any layout
                  event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
                  event.window.map({ self.gameWindows.contains($0) }) ?? (self.gameWindow != nil)
            else { return event }
            switch self.quitGuard.press(at: event.timestamp, isRepeat: event.isARepeat) {
            case .quit:
                Self.lifecycleLogger.notice("⌘Q guard: second press, quitting")
                return event
            case .warn:
                Self.lifecycleLogger.notice("⌘Q guard: first press swallowed, warning shown")
                self.quitGuardWarning?()
                return nil
            case .ignore: return nil
            }
        }
    }

    // MARK: Other Spaces

    /// UIKitMacHelper backgrounds the whole app when no window is visible. On each window change,
    /// `-[UINSWindowStateController _updateWindowState:forWindow:sceneIdentifier:performingStateChangeIfNecessary:]`
    /// reads the window itself (minimised, on the active Space, visible, tabbed out), logs
    /// "Window state changed: ... onInvisibleSpace: 1" and sends the app to the background from
    /// those fresh values; the stored `_UINSWindowState` only records them afterwards (hooking its
    /// setter, build 916, changed nothing). The update is skipped only when the one change is that
    /// a visible, not minimised game window is on another Space: switching Spaces then makes the game
    /// inactive, as losing focus does. Minimising, hiding and closing still background it, and the
    /// hidden-window throttle keeps it cheap.
    nonisolated(unsafe) private static var keepOnOtherSpaces = false
    private static var otherSpacesHookInstalled = false

    /// The skip rule, testable without UIKit: only the invisible Space differs from "on screen".
    nonisolated static func skipsSpaceUpdate(enabled: Bool, minimized: Bool, visible: Bool, onActiveSpace: Bool) -> Bool {
        enabled && !minimized && visible && !onActiveSpace
    }

    /// The bridge whose game windows decide an update.
    private static weak var spacesBridge: AppKitBridge?

    /// Whether this update may record the window state without acting on it: the window is a game window
    /// merely on another Space, and UIKit already tracks the scene. UIKit's own bookkeeping always runs;
    /// skipping the whole update (build 921) left a just-opened scene untracked, and
    /// -[UINSWindowStateController didOpenWindowForScene:] then asserted (Bleach, 2026-10-10 00:53).
    private static func holdsStateChange(controller: AnyObject, scene: AnyObject?, window: NSWindow?) -> Bool {
        guard keepOnOtherSpaces, let bridge = spacesBridge, let controller = controller as? NSObject else { return false }
        let complete = NSSelectorFromString("initialWindowOpeningComplete")
        guard controller.responds(to: complete) else { return false }
        typealias GetBool = @convention(c) (AnyObject, Selector) -> Bool
        guard unsafeBitCast(controller.method(for: complete), to: GetBool.self)(controller, complete) else { return false }
        var gameWindow = window
        if let scene {
            let states = NSSelectorFromString("scenesToWindowStates"), windowFor = NSSelectorFromString("windowForScene:")
            guard controller.responds(to: states), controller.responds(to: windowFor),
                  let table = controller.perform(states)?.takeUnretainedValue() as? NSMapTable<AnyObject, AnyObject>,
                  table.object(forKey: scene) != nil,
                  let sceneWindow = controller.perform(windowFor, with: scene)?.takeUnretainedValue() as? NSWindow
            else { return false }
            gameWindow = sceneWindow
        }
        guard let gameWindow, bridge.gameWindows.contains(gameWindow) else { return false }
        return skipsSpaceUpdate(enabled: true, minimized: gameWindow.isMiniaturized, visible: gameWindow.isVisible,
                                onActiveSpace: gameWindow.isOnActiveSpace)
    }

    public func keepForegroundOnOtherSpaces(_ enabled: Bool) {
        Self.keepOnOtherSpaces = enabled
        Self.spacesBridge = self
        guard enabled, !Self.otherSpacesHookInstalled else { return }
        Self.otherSpacesHookInstalled = true
        guard let cls = NSClassFromString("UINSWindowStateController") else {
            Self.lifecycleLogger.notice("Other Spaces: UINSWindowStateController not found; UIKit backgrounds as before")
            return
        }
        // macOS 27 (read from the runtime on this Mac, 2026-10-10): a scene and a window variant, (object, BOOL);
        // the scene variant logs "onInvisibleSpace: 1" and backgrounds the game. Older macOS: one update taking
        // (state, window, scene identifier, BOOL). Every call reaches UIKit; only the state change is withheld.
        var installed: [String] = []
        typealias Update2 = @convention(c) (AnyObject, Selector, AnyObject?, Bool) -> Void
        let sceneSelector = NSSelectorFromString("_updateWindowStateForScene:performingStateChangeIfNecessary:")
        if let method = class_getInstanceMethod(cls, sceneSelector), method_getNumberOfArguments(method) == 4 {
            let original = method_getImplementation(method)
            let block: @convention(block) (AnyObject, AnyObject?, Bool) -> Void = { controller, scene, perform in
                let hold = perform && MainActor.assumeIsolated { Self.holdsStateChange(controller: controller, scene: scene, window: nil) }
                unsafeBitCast(original, to: Update2.self)(controller, sceneSelector, scene, perform && !hold)
            }
            if Self.installQuitHook(cls, selector: sceneSelector, replacement: imp_implementationWithBlock(block),
                                    result: "v", arguments: ["@", "B"]) { installed.append("scene") }
        }
        let windowSelector = NSSelectorFromString("_updateWindowStateForWindow:performingStateChangeIfNecessary:")
        if let method = class_getInstanceMethod(cls, windowSelector), method_getNumberOfArguments(method) == 4 {
            let original = method_getImplementation(method)
            let block: @convention(block) (AnyObject, AnyObject?, Bool) -> Void = { controller, window, perform in
                let hold = perform && MainActor.assumeIsolated {
                    Self.holdsStateChange(controller: controller, scene: nil, window: window as? NSWindow)
                }
                unsafeBitCast(original, to: Update2.self)(controller, windowSelector, window, perform && !hold)
            }
            if Self.installQuitHook(cls, selector: windowSelector, replacement: imp_implementationWithBlock(block),
                                    result: "v", arguments: ["@", "B"]) { installed.append("window") }
        }
        let legacySelector = NSSelectorFromString("_updateWindowState:forWindow:sceneIdentifier:performingStateChangeIfNecessary:")
        if let method = class_getInstanceMethod(cls, legacySelector), method_getNumberOfArguments(method) == 6 {
            let original = method_getImplementation(method)
            typealias Update4 = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, Bool) -> Void
            let block: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?, Bool) -> Void = { controller, state, window, scene, perform in
                let hold = perform && MainActor.assumeIsolated {
                    Self.holdsStateChange(controller: controller, scene: nil, window: window as? NSWindow)
                }
                unsafeBitCast(original, to: Update4.self)(controller, legacySelector, state, window, scene, perform && !hold)
            }
            if Self.installQuitHook(cls, selector: legacySelector, replacement: imp_implementationWithBlock(block),
                                    result: "v", arguments: ["@", "@", "@", "B"]) { installed.append("legacy") }
        }
        if installed.isEmpty {
            Self.lifecycleLogger.notice("Other Spaces: no UINSWindowStateController update matched; UIKit backgrounds as before")
        } else {
            Self.lifecycleLogger.notice("Other Spaces: game stays in the foreground, hooks: \(installed.joined(separator: ", "), privacy: .public)")
        }
    }

    private static let lifecycleLogger = Logger(subsystem: "io.mulg", category: "bridge")

    // MARK: Full-screen shape

    /// The content shape each game window keeps in full screen (exact resolutions, custom ratios).
    private static let fullScreenShapes = NSMapTable<NSWindow, NSValue>.weakToStrongObjects()
    private static var fullScreenFitClasses: Set<ObjectIdentifier> = []
    private static var loggedMissingDelegate = false

    /// The fitted full-screen content size: the largest size of `shape` inside `proposed`.
    nonisolated static func fullScreenSize(proposed: NSSize, shape: NSSize?) -> NSSize {
        guard let shape, shape.width > 0, shape.height > 0, proposed.width > 0, proposed.height > 0 else { return proposed }
        let ratio = shape.width / shape.height
        if proposed.width / proposed.height > ratio {
            return NSSize(width: (proposed.height * ratio).rounded(.down), height: proposed.height)
        }
        return NSSize(width: proposed.width, height: (proposed.width / ratio).rounded(.down))
    }

    /// `window:willUseFullScreenContentSize:` on the game window's (UIKit) delegate, so a fixed
    /// resolution keeps its shape in full screen instead of being stretched to the display's.
    /// Windows without a shape get the size AppKit proposes, as before.
    private static func installFullScreenFit(for window: NSWindow) {
        guard let delegate = window.delegate, let cls = object_getClass(delegate) else {
            guard !loggedMissingDelegate else { return }
            loggedMissingDelegate = true
            lifecycleLogger.notice("Full-screen shape: the game window has no delegate; full screen fills the display")
            return
        }
        guard !fullScreenFitClasses.contains(ObjectIdentifier(cls)) else { return }
        let selector = NSSelectorFromString("window:willUseFullScreenContentSize:")
        let method = class_getInstanceMethod(cls, selector)
        if let method {
            // NSSize reply, a window and an NSSize. Leave a changed ABI untouched.
            guard method_getNumberOfArguments(method) == 4 else { return }
            let type = method_copyReturnType(method)
            defer { free(type) }
            guard String(cString: type).hasPrefix("{CGSize") else { return }
        }
        fullScreenFitClasses.insert(ObjectIdentifier(cls))
        let encoding = "{CGSize=dd}"
        if method == nil {
            let native: @convention(block) (AnyObject, NSWindow, NSSize) -> NSSize = { _, _, proposed in proposed }
            class_addMethod(cls, selector, imp_implementationWithBlock(native), encoding + "@:@" + encoding)
        }
        guard let original = class_getMethodImplementation(cls, selector) else { return }
        typealias WillUse = @convention(c) (AnyObject, Selector, NSWindow, NSSize) -> NSSize
        let block: @convention(block) (AnyObject, NSWindow, NSSize) -> NSSize = { object, window, proposed in
            let native = unsafeBitCast(original, to: WillUse.self)(object, selector, window, proposed)
            return MainActor.assumeIsolated {
                fullScreenSize(proposed: native, shape: fullScreenShapes.object(forKey: window)?.sizeValue)
            }
        }
        guard installQuitHook(cls, selector: selector, replacement: imp_implementationWithBlock(block),
                              result: encoding, arguments: ["@", encoding]) else { 
            lifecycleLogger.notice("Full-screen shape: hook on \(NSStringFromClass(cls), privacy: .public) refused")
            return
        }
        lifecycleLogger.notice("Full-screen shape: kept in full screen by \(NSStringFromClass(cls), privacy: .public)")
        // AppKit may cache what a delegate answers when it is set; set the same delegate again.
        window.delegate = delegate
    }

    public func observeTermination(_ handler: @escaping () -> Void) {
        terminationHandler = handler
        guard Self.quitBridge == nil, let delegate = NSApplication.shared.delegate,
              let cls = object_getClass(delegate) else { return }
        let should = #selector(NSApplicationDelegate.applicationShouldTerminate(_:))
        let method = class_getInstanceMethod(cls, should)
        // NSUInteger reply and one object argument. Leave a changed ABI untouched.
        if let method {
            guard method_getNumberOfArguments(method) == 3 else { return }
            let type = method_copyReturnType(method)
            defer { free(type) }
            guard String(cString: type) == "Q" else { return }
        }
        let original = method.map(method_getImplementation)
        typealias Should = @convention(c) (AnyObject, Selector, NSApplication) -> UInt
        let block: @convention(block) (AnyObject, NSApplication) -> UInt = { object, app in
            MainActor.assumeIsolated {
                let native = original.map { unsafeBitCast($0, to: Should.self)(object, should, app) }
                    ?? NSApplication.TerminateReply.terminateNow.rawValue
                guard let bridge = Self.quitBridge, !bridge.shutdownFinished else { return native }
                guard native == NSApplication.TerminateReply.terminateNow.rawValue else {
                    // UIKit defers the quit while the game holds background tasks; a game that keeps
                    // starting them (Ragnarok, 2026-10-09) never quits. Arm the engine's deadline.
                    if native == NSApplication.TerminateReply.terminateLater.rawValue { bridge.reportDeferredTermination() }
                    return native
                }
                bridge.beginQuit()
                return NSApplication.TerminateReply.terminateLater.rawValue
            }
        }
        let reply = #selector(NSApplication.reply(toApplicationShouldTerminate:))
        guard let replyMethod = class_getInstanceMethod(NSApplication.self, reply) else { return }
        let replyOriginal = method_getImplementation(replyMethod)
        guard let replyType = method_copyArgumentType(replyMethod, 2) else { return }
        defer { free(replyType) }
        let booleanType = String(cString: replyType)
        guard ["B", "c"].contains(booleanType) else { return }
        typealias Reply = @convention(c) (NSApplication, Selector, Bool) -> Void
        let replyBlock: @convention(block) (NSApplication, Bool) -> Void = { app, accepted in
            MainActor.assumeIsolated {
                if accepted, let bridge = Self.quitBridge, !bridge.shutdownFinished {
                    bridge.beginQuit()
                } else {
                    unsafeBitCast(replyOriginal, to: Reply.self)(app, reply, accepted)
                }
            }
        }
        guard Self.installQuitHook(NSApplication.self, selector: reply, replacement: imp_implementationWithBlock(replyBlock),
                                   result: "v", arguments: [booleanType]) else { return }
        if method == nil {
            let native: @convention(block) (AnyObject, NSApplication) -> UInt = { _, _ in NSApplication.TerminateReply.terminateNow.rawValue }
            class_addMethod(cls, should, imp_implementationWithBlock(native), "Q@:@")
        }
        guard Self.installQuitHook(cls, selector: should, replacement: imp_implementationWithBlock(block),
                                   result: "Q", arguments: ["@"]) else { return }
        Self.quitBridge = self
    }

    public func observeDeferredTermination(_ handler: @escaping () -> Void) {
        deferredTerminationHandler = handler
    }

    private func reportDeferredTermination() {
        guard !deferredTerminationReported else { return }
        deferredTerminationReported = true
        DispatchQueue.main.async { [weak self] in self?.deferredTerminationHandler?() }
    }

    private func beginQuit() {
        guard !quitPending else { return }
        quitPending = true
        // Let AppKit enter its termination state before completing the deferred reply.
        DispatchQueue.main.async { [weak self] in self?.terminationHandler?() }
    }

    // MARK: Cursor

    public var mousePoint: CGPoint {
        gameWindow?.mouseLocationOutsideOfEventStream ?? .zero
    }

    public func hideCursor() {
        cursorCaptureRequested = true
        updateCursorCapture()
    }

    public func unhideCursor() {
        cursorCaptureRequested = false
        updateCursorCapture()
        NSCursor.setHiddenUntilMouseMoves(false)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    public func setPointerCursorHidden(_ hidden: Bool) {
        pointerCursorHiddenRequested = hidden
        updatePointerCursorVisibility()
        NSCursor.setHiddenUntilMouseMoves(false)
        // UIKit owns native pointer locking. Reassociating here would undo the lock
        // immediately after setNeedsUpdateOfPrefersPointerLocked requested it.
    }

    private func updatePointerCursorVisibility() {
        let hidden = pointerCursorHiddenRequested && nativeWindowButtons.isEmpty
            && NSApplication.shared.isActive && gameWindow?.isKeyWindow == true
        guard hidden != pointerCursorHidden else { return }
        pointerCursorHidden = hidden
        if hidden { NSCursor.hide() } else { NSCursor.unhide() }
    }

    private func updateCursorCapture() {
        updatePointerCursorVisibility()
        if cursorCaptureRequested, nativeWindowButtons.isEmpty, NSApplication.shared.isActive,
           let window = gameWindow, window.isKeyWindow {
            if !cursorHidden {
                NSCursor.setHiddenUntilMouseMoves(false)
                NSCursor.hide()
                cursorHidden = true
            }
            if cursorLockWindow !== window { lockCursor(in: window) }
            return
        }
        guard cursorHidden else { return }
        cursorHidden = false
        cursorLockWindow = nil
        cursorLockPoint = nil
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
    }

    private func lockCursor(in window: NSWindow) {
        cursorLockWindow = window
        let associated = CGAssociateMouseAndMouseCursorPosition(0)
        let point = centerCursor(in: window)
        cursorLockPoint = associated == .success ? point : nil
        nextCursorRepair = DispatchTime.now().uptimeNanoseconds + 100_000_000
    }

    /// The window owns relative mouse input while locked, even if an event arrived
    /// with stale window-edge coordinates or without a window number.
    private func ownsCapturedPointer(_ event: NSEvent) -> Bool {
        let eventWindow = event.window
        guard cursorHidden, let window = cursorLockWindow, window === gameWindow,
              Self.routesGameplayEvent(window: eventWindow, game: window,
                active: NSApplication.shared.isActive, allowsUnassignedPointer: true) else { return false }
        let reported = eventWindow == nil ? event.locationInWindow : window.convertPoint(toScreen: event.locationInWindow)
        if let anchor = cursorLockPoint, Self.nearCursorAnchor(reported, anchor) { return true }
        // Check the current cursor before repairing: a queued event from before the warp can
        // still carry the old position. Limit retries if the window server refuses capture.
        if DispatchTime.now().uptimeNanoseconds >= nextCursorRepair,
           cursorLockPoint.map({ !Self.nearCursorAnchor(NSEvent.mouseLocation, $0) }) ?? true {
            lockCursor(in: window)
        }
        return true
    }

    private static func nearCursorAnchor(_ point: CGPoint, _ anchor: CGPoint) -> Bool {
        abs(point.x - anchor.x) <= 2 && abs(point.y - anchor.y) <= 2
    }

    func beginWindowInteraction(button: Int) {
        nativeWindowButtons.insert(button)
        updateCursorCapture()
    }

    func endWindowInteraction(button: Int) {
        guard nativeWindowButtons.remove(button) != nil else { return }
        // Let AppKit finish handling mouse-up before moving or capturing the cursor again.
        DispatchQueue.main.async { [weak self] in self?.updateCursorCapture() }
    }

    public func warpCursor() {
        guard nativeWindowButtons.isEmpty, let window = gameWindow else { return }
        _ = centerCursor(in: window)
    }

    private func centerCursor(in window: NSWindow) -> CGPoint? {
        guard let firstScreen = NSScreen.screens.first else { return nil }
        let content = window.contentLayoutRect
        guard !content.isEmpty else { return nil }
        let point = window.convertPoint(toScreen: CGPoint(x: content.midX, y: content.midY))
        // AppKit's origin is bottom-left, Core Graphics' is top-left.
        let result = CGWarpMouseCursorPosition(CGPoint(x: point.x, y: firstScreen.frame.maxY - point.y))
        return result == .success ? point : nil
    }

    public func hideCursorUntilMouseMoves() {
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    // MARK: Pointer confinement

    private var confinementRequested = false
    /// The player showed the cursor (Alt or a middle click). Nothing is confined otherwise.
    private var cursorReleasedByPlayer = false
    private var confinementTimer: Timer?
    private var confinementMonitor: Any?
    private var confinementObservers: [NSObjectProtocol] = []
    private let confinementTap = PointerConfinementTap()

    public func setCursorReleasedByPlayer(_ released: Bool) {
        guard released != cursorReleasedByPlayer else { return }
        cursorReleasedByPlayer = released
        if confinementRequested { enforcePointerConfinement() }
    }

    /// See `MacBridge.confinePointer` and `PointerConfinement`.
    public func confinePointer(_ enabled: Bool) {
        guard enabled != confinementRequested else { return }
        confinementRequested = enabled
        guard enabled else {
            confinementTimer?.invalidate()
            confinementTimer = nil
            if let confinementMonitor { NSEvent.removeMonitor(confinementMonitor) }
            confinementMonitor = nil
            confinementObservers.forEach { NotificationCenter.default.removeObserver($0) }
            confinementObservers = []
            confinementTap.uninstall()
            return
        }
        // A warp otherwise freezes local mouse input for a quarter of a second at every edge.
        CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0
        confinementTap.installIfAllowed()
        // Moves the cursor back as soon as an event shows it got out; it never changes or drops the event.
        confinementMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged,
            .rightMouseDragged, .otherMouseDragged]) { [weak self] event in
            self?.enforcePointerConfinement()
            return event
        }
        // The poll runs only while Mulg's game is the active app, so a game in the background costs nothing.
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            confinementObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateConfinementTimer() }
            })
        }
        updateConfinementTimer()
    }

    private func updateConfinementTimer() {
        let app = NSApplication.shared
        guard confinementRequested, app.isActive, !app.isHidden else {
            confinementTimer?.invalidate()
            confinementTimer = nil
            confinementTap.setRegion(nil)
            return
        }
        if confinementTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.enforcePointerConfinement() }
            }
            timer.tolerance = 0.002
            // Common modes: also while a menu or a native control tracks the mouse.
            RunLoop.main.add(timer, forMode: .common)
            confinementTimer = timer
        }
        enforcePointerConfinement()
    }

    /// The part of the screen the pointer must stay in now (AppKit coordinates), or nil when
    /// the pointer is free.
    private var pointerConfinementRegion: CGRect? {
        let app = NSApplication.shared
        guard confinementRequested, let window = gameWindow else { return nil }
        let transitioning = windowStates.object(forKey: window)?.fullscreen?.isTransitioning == true
        guard PointerConfinement.applies(requested: true, released: cursorReleasedByPlayer && !pointerCursorHiddenRequested
                    && !cursorCaptureRequested, active: app.isActive, hidden: app.isHidden,
                gameKey: window.isKeyWindow, minimized: window.isMiniaturized, onActiveSpace: window.isOnActiveSpace,
                windowInteraction: !nativeWindowButtons.isEmpty,
                resizing: window.inLiveResize || !resizingWindows.allObjects.isEmpty,
                transitioning: transitioning,
                // A locked camera cursor is already held by the window server; a refused lock is not.
                captured: cursorHidden && cursorLockPoint != nil) else { return nil }
        return PointerConfinement.region(content: window.convertToScreen(window.contentLayoutRect),
                                         resizable: window.styleMask.contains(.resizable),
                                         fullscreen: window.styleMask.contains(.fullScreen))
    }

    private func enforcePointerConfinement() {
        guard let region = pointerConfinementRegion, let firstScreen = NSScreen.screens.first else {
            confinementTap.setRegion(nil)
            return
        }
        let top = firstScreen.frame.maxY
        confinementTap.setRegion(PointerConfinement.flipped(region, firstScreenMaxY: top))
        let mouse = NSEvent.mouseLocation
        guard !PointerConfinement.contains(mouse, region) else { return }
        let target = PointerConfinement.clamp(mouse, to: region)
        _ = CGWarpMouseCursorPosition(PointerConfinement.flipped(target, firstScreenMaxY: top))
    }

    // MARK: Input

    public var isTextInputActive: Bool {
        let responder = NSApplication.shared.keyWindow?.firstResponder
        if let text = responder as? NSTextView, text.isEditable { return true }
        if let field = responder as? NSTextField, field.isEditable && field.isEnabled { return true }
        return (responder as? any NSTextInputClient)?.hasMarkedText() == true
    }

    func acceptsGameplayEvent(_ event: NSEvent) -> Bool {
        Self.routesGameplayEvent(window: event.window, game: gameWindow, active: NSApplication.shared.isActive)
    }
    static func routesGameplayEvent(window: NSWindow?, game: NSWindow?, active: Bool,
                                    allowsUnassignedPointer: Bool = false) -> Bool {
        guard active, let game, game.isKeyWindow else { return false }
        return window === game || (window == nil && allowsUnassignedPointer)
    }

    /// Window coordinates include the title bar; content coordinates do not. The frame's
    /// resize border belongs to AppKit rather than the game's attack/touch mappings.
    static func routesGameplayPointer(point: CGPoint, contentRect: CGRect, frameSize: CGSize,
                                      resizable: Bool, fullscreen: Bool) -> Bool {
        guard contentRect.contains(point) else { return false }
        if resizable && !fullscreen {
            return CGRect(origin: .zero, size: frameSize).insetBy(dx: 10, dy: 10).contains(point)
        }
        return true
    }

    func isWindowManagementEvent(_ event: NSEvent) -> Bool {
        guard let window = event.window else { return false }
        return isInTrafficLightArea(event) || !Self.routesGameplayPointer(
            point: event.locationInWindow, contentRect: window.contentLayoutRect,
            frameSize: window.frame.size, resizable: window.styleMask.contains(.resizable),
            fullscreen: window.styleMask.contains(.fullScreen))
    }

    private func monitor(_ mask: NSEvent.EventTypeMask, gameplay: Bool = false, _ handler: @escaping (NSEvent) -> NSEvent?) {
        if let token = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard !gameplay || self?.acceptsGameplayEvent(event) == true else { return event }
            return handler(event)
        }) {
            eventMonitors.append(token)
        }
    }

    public func setupKeyboard(_ handler: @escaping (UInt16, Bool, Bool, UInt) -> Bool) {
        monitor(.keyDown) { [weak self] event in
            guard let self, self.acceptsGameplayEvent(event) else { return event }
            self.pressedKeys.insert(event.keyCode)
            let consumed = handler(event.keyCode, true, event.isARepeat, event.modifierFlags.rawValue)
            if consumed { self.consumedKeys.insert(event.keyCode) }
            return consumed || self.consumedKeys.contains(event.keyCode) ? nil : event
        }
        monitor(.keyUp) { [weak self] event in
            guard let self, self.pressedKeys.remove(event.keyCode) != nil else { return event }
            let owned = self.consumedKeys.remove(event.keyCode) != nil
            _ = handler(event.keyCode, false, false, event.modifierFlags.rawValue)
            return owned ? nil : event
        }
    }

    public func setupModifierKeys(_ handler: @escaping (UInt16, Bool, UInt) -> Bool) {
        monitor(.flagsChanged) { [weak self] event in
            guard let pressed = Self.modifierPressed(code: event.keyCode, flags: event.modifierFlags) else { return event }
            guard let self else { return event }
            if pressed {
                guard self.acceptsGameplayEvent(event) else { return event }
                self.pressedModifiers.insert(event.keyCode)
            } else if self.pressedModifiers.remove(event.keyCode) == nil { return event }
            let owned = self.consumedModifiers.contains(event.keyCode)
            let consumed = handler(event.keyCode, pressed, event.modifierFlags.rawValue)
            if pressed, consumed { self.consumedModifiers.insert(event.keyCode) }
            if !pressed { self.consumedModifiers.remove(event.keyCode) }
            return (pressed ? consumed : owned) ? nil : event
        }
    }

    private static func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 0x37, 0x36: .command
        case 0x38, 0x3C: .shift
        case 0x3A, 0x3D: .option
        case 0x3B, 0x3E: .control
        case 0x39: .capsLock
        case 0x3F: .function
        default: nil
        }
    }

    /// AppKit's public Shift/Control/Option/Command flags combine both sides. The
    /// device bits identify the key that changed, even while its partner stays down.
    static func modifierPressed(code: UInt16, flags: NSEvent.ModifierFlags) -> Bool? {
        guard let flag = modifierFlag(for: code) else { return nil }
        let sides: (own: UInt, pair: UInt)? = switch code {
        case 0x3B: (0x0001, 0x2001) // NX_DEVICELCTLKEYMASK
        case 0x3E: (0x2000, 0x2001) // NX_DEVICERCTLKEYMASK
        case 0x38: (0x0002, 0x0006) // NX_DEVICELSHIFTKEYMASK
        case 0x3C: (0x0004, 0x0006) // NX_DEVICERSHIFTKEYMASK
        case 0x37: (0x0008, 0x0018) // NX_DEVICELCMDKEYMASK
        case 0x36: (0x0010, 0x0018) // NX_DEVICERCMDKEYMASK
        case 0x3A: (0x0020, 0x0060) // NX_DEVICELALTKEYMASK
        case 0x3D: (0x0040, 0x0060) // NX_DEVICERALTKEYMASK
        default: nil
        }
        if let sides, flags.rawValue & sides.pair != 0 {
            return flags.rawValue & sides.own != 0
        }
        return flags.contains(flag)
    }

    public func setupMouseMoved(_ handler: @escaping (CGFloat, CGFloat) -> Bool) {
        monitor([.leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] event in
            // A title-bar/edge press never entered pressedButtons. Its drag must stay native
            // for its entire lifetime, even when it moves back over the content view.
            guard let self, self.pressedButtons.contains(event.buttonNumber) else { return event }
            // A native content press owns its drag too. Entering mapped camera
            // mode mid-drag cannot take movement away from its native recipient.
            guard self.consumedButtons.contains(event.buttonNumber),
                  self.ownsCapturedPointer(event) || self.acceptsGameplayEvent(event) else { return event }
            _ = handler(event.deltaX, event.deltaY)
            return nil
        }
        // Window chrome keeps its native hover stream. A consumed gameplay movement
        // must not reach native mouse input as well as its synthesized touch.
        monitor(.mouseMoved) { [weak self] event in
            guard let self, self.ownsCapturedPointer(event) || (self.acceptsGameplayEvent(event)
                && self.nativeWindowButtons.isEmpty && !self.isWindowManagementEvent(event)) else { return event }
            return handler(event.deltaX, event.deltaY) ? nil : event
        }
    }

    public func setupMouseButtons(_ handler: @escaping (Int, Bool) -> Bool) {
        let downs: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let ups: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        monitor(downs) { [weak self] event in
            guard let self else { return event }
            if !self.ownsCapturedPointer(event) {
                guard event.window === self.gameWindow else { return event }
                if self.isInTrafficLightArea(event) {
                    self.beginWindowInteraction(button: event.buttonNumber)
                    return event
                }
                if event.type == .leftMouseDown, event.clickCount == 2, self.preferences.hideTitleBar,
                   let window = event.window, event.locationInWindow.y > window.contentLayoutRect.maxY {
                    self.beginWindowInteraction(button: event.buttonNumber)
                    window.performZoom(nil)
                    return nil
                }
                // Clicks in other windows (for example the full-screen title bar) pass through.
                if !self.nativeWindowButtons.isEmpty || self.isWindowManagementEvent(event) {
                    self.beginWindowInteraction(button: event.buttonNumber)
                    return event
                }
                if !self.acceptsGameplayEvent(event) { return event }
            }
            self.pressedButtons.insert(event.buttonNumber)
            let consumed = handler(event.buttonNumber, true)
            if consumed { self.consumedButtons.insert(event.buttonNumber) }
            return consumed ? nil : event
        }
        // A release goes to the game only when its press did, so a click in the title bar or
        // another window keeps its release.
        monitor(ups) { [weak self] event in
            guard let self else { return event }
            if self.nativeWindowButtons.contains(event.buttonNumber) {
                self.endWindowInteraction(button: event.buttonNumber)
                return event
            }
            guard self.pressedButtons.remove(event.buttonNumber) != nil else { return event }
            let owned = self.consumedButtons.remove(event.buttonNumber) != nil
            _ = handler(event.buttonNumber, false)
            return owned ? nil : event
        }
    }

    private func isInTrafficLightArea(_ event: NSEvent) -> Bool {
        guard let window = event.window else { return false }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = window.standardWindowButton(type),
               button.bounds.contains(button.convert(event.locationInWindow, from: nil)) {
                return true
            }
        }
        return false
    }

    public func setupScrollWheel(_ handler: @escaping (CGFloat, CGFloat) -> Bool) {
        monitor(.scrollWheel) { [weak self] event in
            guard let self, self.ownsCapturedPointer(event) || self.acceptsGameplayEvent(event) else { return event }
            var deltaX = event.scrollingDeltaX
            var deltaY = event.scrollingDeltaY
            if !event.hasPreciseScrollingDeltas {
                // Mouse wheels report lines; convert to points like upstream.
                deltaX *= 16
                deltaY *= 16
            }
            return handler(deltaX, deltaY) ? nil : event
        }
    }

    public func setupMagnify(_ handler: @escaping (CGFloat, Int) -> Bool) {
        monitor(.magnify, gameplay: true) { event in
            handler(event.magnification, Self.phaseCode(event.phase)) ? nil : event
        }
    }

    public func setupRotate(_ handler: @escaping (CGFloat, Int) -> Bool) {
        monitor(.rotate, gameplay: true) { event in
            handler(CGFloat(event.rotation), Self.phaseCode(event.phase)) ? nil : event
        }
    }

    static func phaseCode(_ phase: NSEvent.Phase) -> Int {
        if phase.contains(.cancelled) { return 4 }
        if phase.contains(.began) { return 1 }
        if phase.contains(.ended) { return 3 }
        return 2
    }

    // MARK: Metal

    public func setDisplaySyncEnabled(_ enabled: Bool, on layer: CALayer) -> Bool {
        guard let metalLayer = layer as? CAMetalLayer else { return false }
        metalLayer.displaySyncEnabled = enabled
        return true
    }

    public func displaySyncEnabled(on layer: CALayer) -> Bool {
        (layer as? CAMetalLayer)?.displaySyncEnabled ?? true
    }

    public func maximizeShaderCompilation(on device: any MTLDevice) -> Bool {
        device.shouldMaximizeConcurrentCompilation = true
        return device.shouldMaximizeConcurrentCompilation
    }

    // MARK: Application

    public func terminateApplication() {
        shutdownFinished = true
        if quitPending { NSApplication.shared.reply(toApplicationShouldTerminate: true) }
        else { NSApplication.shared.terminate(self) }
    }

    public func urlForApplication(bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }
}
#endif
