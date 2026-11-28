import CoreGraphics
import Foundation
import Metal
import QuartzCore

/// The only route from the iOS game process to macOS-only APIs (PLAN.md §1.3, §1.5 rule 2).
///
/// The game runs as an iOS app, so it cannot link AppKit. The implementation lives in a
/// separate macOS bundle (`MulgBridgeAppKit`) that the runtime loads at start-up, as
/// upstream's MulgAppKit plug-in did. This protocol is the contract between the two; it is
/// an Objective-C protocol so the bundle's principal class can be cast to it.
///
/// Compared with upstream's `Plugin`, it adds display refresh rate and HDR headroom, power
/// source, window visibility, full screen, vsync control for Metal layers, modifier key
/// releases (for hold-Option), trackpad gestures, and window preferences passed in by the
/// runtime instead of read from a hard-coded settings path.
@MainActor
@objc(MulgMacBridge)
public protocol MacBridge: NSObjectProtocol {
    init()

    // MARK: Screens and window

    var screenCount: Int { get }
    var mainScreenFrame: CGRect { get }
    var isMainScreenEqualToFirst: Bool { get }
    var windowFrame: CGRect { get }
    @objc optional func bindGameLayer(_ layer: CALayer)
    /// A normalized top-left game-surface rectangle inside the native content view.
    /// Optional and permission-gated; returns bounded top-left grayscale bytes, not Metal buffers.
    @objc optional func captureGameHUD(in rect: CGRect, requestPermission: Bool,
                                      completion: @escaping (Data?, Int, Int, String?) -> Void)
    var isFullscreen: Bool { get }
    /// Whether any part of the game window is visible on screen.
    var isWindowVisible: Bool { get }
    /// Highest refresh rate of the display showing the game window, in Hz.
    var displayMaximumRefreshRate: Int { get }
    /// Whether that display varies its refresh rate (ProMotion, Adaptive-Sync). Optional: a
    /// bridge from an older injection does not have it.
    @objc optional var displayHasVariableRefresh: Bool { get }
    /// Potential HDR headroom of that display (1 = no HDR).
    var displayEDRHeadroom: CGFloat { get }
    func toggleFullScreen()
    func setMenuBarVisible(_ visible: Bool)
    /// Registered wrapper commands with explicit native targets. An empty list removes the menu.
    /// Optional so an older bridge retains the runtime's UIKit fallback.
    @objc optional func installGameMenu(_ commands: [[String: Any]], title: String,
                                       perform: @escaping (String) -> Void)
    /// Applies window options from the game's settings (hide title bar, floating window,
    /// fixed aspect ratio; 0 × 0 means free).
    func applyWindowPreferences(hideTitleBar: Bool, floating: Bool, aspectWidth: Int, aspectHeight: Int)
    /// Resizable windows: reopen at the size and place the game window had last time (saved in
    /// the game's own defaults). Fixed resolution presets keep their sizes.
    @objc optional func rememberWindowFrame(_ remember: Bool)

    // MARK: Power

    var isOnBatteryPower: Bool { get }

    // MARK: Observation (handlers run on the main thread)

    /// Called with the new maximum refresh rate when the window moves to another display
    /// or the display changes, and when the window enters or leaves full screen.
    func observeDisplayChanges(_ handler: @escaping (Int) -> Void)
    /// Called when the window becomes hidden or visible.
    func observeWindowVisibility(_ handler: @escaping (Bool) -> Void)
    /// Called with true when the user starts resizing the game window and false when they stop.
    @objc optional func observeLiveResize(_ handler: @escaping (Bool) -> Void)
    /// Called when the Mac switches between battery (true) and mains power (false).
    func observePowerSource(_ handler: @escaping (Bool) -> Void)
    /// Called whenever the game window's focus or visibility may have changed, with whether it
    /// has the keyboard focus and whether it is on screen (not minimised, the game not hidden).
    /// Optional: a bridge from an older injection does not have it.
    @objc optional func observeWindowFocus(_ handler: @escaping (Bool, Bool) -> Void)
    /// Called with whether the player is using the game: it is the active app, not hidden, and a game
    /// window is not minimised and really visible (not covered, on another Space, or in another app's full
    /// screen). Mulg's own windows in the game (editor, notices) keep it in use. For engine.muteWhenUnfocused.
    @objc optional func observeGameInUse(_ handler: @escaping (Bool) -> Void)
    /// Called when the user closes the game window, just before it closes, so the game can
    /// be sent through a normal iOS shutdown (upstream quitWhenClose).
    func observeWindowClosing(_ handler: @escaping () -> Void)
    /// Normal Quit requests, after the native delegate accepts termination.
    @objc optional func observeTermination(_ handler: @escaping () -> Void)
    /// Quit requests the native delegate deferred (UIKit waiting for the game's background tasks).
    /// A game that keeps starting tasks never finishes such a quit; the engine arms its deadline.
    @objc optional func observeDeferredTermination(_ handler: @escaping () -> Void)
    /// ⌘Q in a game window must be pressed twice within two seconds: the first press calls `warn`
    /// and is swallowed (a ⌘Tab slip or a held ⌘ quit games mid-play). Menu, Dock and app quits stay
    /// immediate. `enabled` false restores plain ⌘Q.
    @objc optional func guardQuitShortcut(_ enabled: Bool, warn: @escaping () -> Void)
    /// A game whose window is merely on another Space (a full-screen game while the player looks at
    /// the desktop) stays in the foreground instead of UIKit sending it to the background: games
    /// tear down and reload on background, and lagged or quit on every Space switch.
    @objc optional func keepForegroundOnOtherSpaces(_ enabled: Bool)

    // MARK: Cursor

    var mousePoint: CGPoint { get }
    func hideCursor()
    func unhideCursor()
    func warpCursor()
    func hideCursorUntilMouseMoves()
    /// Pointer interfaces may hide the cursor without locking or recentering it.
    @objc optional func setPointerCursorHidden(_ hidden: Bool)
    /// While the game window is the active app's key window (windowed or full screen) and the player
    /// showed the cursor (`setCursorReleasedByPlayer`), keeps the cursor and every click and drag inside its content, so input never reaches the desktop or
    /// another app mid-game; ⌘Q is the way out. ⌘Tab, hiding, minimising, native window drags and
    /// resizes and full-screen transitions free it. Optional: an older bridge lacks it.
    @objc optional func confinePointer(_ enabled: Bool)
    /// Whether the player showed the cursor (the cursor key, Alt by default, or a middle click).
    /// Confinement applies only then, so camera rotation in 3D games is never touched.
    @objc optional func setCursorReleasedByPlayer(_ released: Bool)

    // MARK: Input (a handler returns true when it consumed the event)

    /// Editable AppKit field or active IME composition. Optional for older bridge bundles.
    @objc optional var isTextInputActive: Bool { get }

    /// Key presses and releases: key code, pressed, auto-repeat, AppKit modifier flags.
    func setupKeyboard(_ handler: @escaping (UInt16, Bool, Bool, UInt) -> Bool)
    /// Modifier keys pressed or released: key code, pressed, AppKit modifier flags.
    func setupModifierKeys(_ handler: @escaping (UInt16, Bool, UInt) -> Bool)
    /// Mouse movement deltas, with or without a button held.
    func setupMouseMoved(_ handler: @escaping (CGFloat, CGFloat) -> Bool)
    /// Mouse buttons: 0 left, 1 right, 2 and above other. Handler gets button and pressed.
    func setupMouseButtons(_ handler: @escaping (Int, Bool) -> Bool)
    /// Scroll deltas in points.
    func setupScrollWheel(_ handler: @escaping (CGFloat, CGFloat) -> Bool)
    /// Trackpad pinch: magnification delta and gesture phase (1 began, 2 changed, 3 ended, 4 cancelled).
    func setupMagnify(_ handler: @escaping (CGFloat, Int) -> Bool)
    /// Trackpad rotation: degrees and gesture phase.
    func setupRotate(_ handler: @escaping (CGFloat, Int) -> Bool)

    // MARK: Metal

    /// Sets `displaySyncEnabled`, which exists on macOS only, on a Metal layer. Returns false
    /// when the layer is not a Metal layer.
    func setDisplaySyncEnabled(_ enabled: Bool, on layer: CALayer) -> Bool
    /// Read through the native bridge: this property is unavailable to Catalyst code.
    @objc optional func displaySyncEnabled(on layer: CALayer) -> Bool

    /// Sets `shouldMaximizeConcurrentCompilation`, which exists on macOS only, on a Metal device,
    /// so the game's shaders compile on as many threads as the Mac allows. Returns whether it
    /// is on. Optional: a bridge from an older injection does not have it.
    @objc optional func maximizeShaderCompilation(on device: any MTLDevice) -> Bool

    // MARK: Application

    /// CoreAudio hardware policy; client PCM buffers and actual session getters stay native.
    /// A zero rate/depth preserves the route's existing format. Reports arrive on main.
    @objc(configureAudioOutputWithSampleRate:bitDepth:protect:report:)
    optional func configureAudioOutput(sampleRate: Double, bitDepth: Int, protect: Bool,
                                      report: @escaping (NSDictionary) -> Void)
    @objc optional func reassertAudioOutput()
    @objc optional func stopAudioOutput(restore: Bool)

    func terminateApplication()
    func urlForApplication(bundleIdentifier: String) -> URL?

    /// Migration only (2026-10-10): the database key an older Mulg kept in the macOS Keychain, or nil.
    /// Keys are now sealed in Mulg's own file (SealedSecret); the bridge never creates a Keychain item, and
    /// behind the keychain wall this read fails. `createIfMissing` is ignored. Any thread.
    @objc optional nonisolated func credentialEncryptionKey(forDatabasePath path: String, createIfMissing: Bool) -> Data?

    /// Migration only: deletes that old Keychain item once the key is sealed in its file. Any thread.
    @objc optional nonisolated func removeLegacyCredentialKey(forDatabasePath path: String)

    /// Standard password accessibility is enforced by native Secure Enclave key agreement.
    /// Only opaque protected envelopes cross this API; missing support must fail closed.
    @objc optional nonisolated func credentialPasswordEnvelope(_ data: Data, accessibility: String, opening: Bool,
        failure: AutoreleasingUnsafeMutablePointer<NSError?>?) -> Data?
}
