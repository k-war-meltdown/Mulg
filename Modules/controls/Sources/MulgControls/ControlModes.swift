import Foundation
import MulgContracts

/// The input mode (upstream ControlModeLiteral).
public enum ControlMode: String, Sendable, Equatable {
    /// Keymapping off: events pass through to the game as plain mouse and keyboard.
    case off
    /// A text field is being edited: keys go to the text field.
    case textInput
    /// The in-game keymap editor.
    case editor
    /// Cursor hidden and locked; the mouse turns the camera.
    case camera
    /// Cursor shown; clicks become taps at the cursor.
    case cursor

    public var hidesCursor: Bool { self == .camera }
}

/// What the controls module must do after a mode change (upstream ControlMode.set).
public struct ModeTransition: Sendable, Equatable {
    public let from: ControlMode
    public let to: ControlMode

    public var cursorShown: Bool { from.hidesCursor && !to.hidesCursor }
    public var cursorHidden: Bool { !from.hidesCursor && to.hidesCursor }

    /// Which touches to release: all when keymapping stops, otherwise only the freely moving
    /// ones, so held buttons (walking) survive the switch (§14.2).
    public enum Release: Sendable, Equatable { case none, nonButtons, all }

    public var release: Release {
        // Key releases no longer reach the keymap in these modes, so nothing may stay held
        // (a key held while a text field opened used to walk on while typing).
        if to == .off || to == .textInput || to == .editor {
            return .all
        }
        return cursorShown || cursorHidden ? .nonButtons : .none
    }
}

/// The mode rules, including hold-Option (PLAN.md §14.2). Pure: the caller performs the
/// transitions it returns.
public struct ControlModeMachine: Sendable, Equatable {
    public private(set) var mode: ControlMode
    public let behaviour: CursorKeyBehaviour
    /// Upstream `noKMOnInput`: keymapping pauses while typing, and "off" becomes "cursor".
    public let pauseForTextInput: Bool
    /// Whether the keymap uses the mouse; without it camera mode is pointless.
    public private(set) var keymapUsesMouse: Bool
    /// Keys the game uses to open its menus (§14.2). Informational only: no key but the cursor key and
    /// the middle button changes the mode (2026-10-12, user request), because Mulg cannot see whether a
    /// menu really opened, and a guessed menu used to leave the camera dead in every 3D game.
    public private(set) var menuKeys: Set<String>

    /// Cursor shown because the cursor key is held (hold mode).
    private var cursorHeld = false
    /// Cursor shown by a click toggle (middle click, a tap of the cursor key): it stays until toggled back.
    /// A keymap refresh used to send such a cursor straight back to the camera, so clicking anything right
    /// after showing it hid it again (2026-10-10).
    private var cursorPinned = false
    /// The cursor is shown, so the player is working a menu (controller bindings use their menu button).
    public var isMenuOpen: Bool { mode == .cursor }
    /// The mode to return to after text input.
    private var beforeTextInput: ControlMode = .cursor
    /// The player showed the cursor themselves (the cursor key or a middle click), as opposed to a
    /// pointer-only map, text input or the editor showing it. Only then does the window border hold the
    /// pointer (`engine.confinePointer`, 2026-11-28 user request); camera mode never confines.
    public private(set) var cursorShownByPlayer = false

    public init(behaviour: CursorKeyBehaviour, pauseForTextInput: Bool, keymapUsesMouse: Bool, menuKeys: Set<String> = []) {
        self.behaviour = behaviour
        self.pauseForTextInput = pauseForTextInput
        self.keymapUsesMouse = keymapUsesMouse
        self.menuKeys = menuKeys
        // Hold mode starts in camera mode (the key shows the cursor); toggle mode starts like
        // upstream, with the cursor shown.
        if behaviour == .hold && keymapUsesMouse {
            mode = .camera
        } else {
            mode = !keymapUsesMouse || pauseForTextInput ? .cursor : .off
        }
    }

    /// Resolve startup after the module has built its actions, before accepting input.
    /// Rebuilding a live keymap does not call this or close an open menu.
    public mutating func activate(usesMouse: Bool) -> ModeTransition? {
        keymapUsesMouse = usesMouse
        guard behaviour == .hold, usesMouse, (mode == idleMode || mode == .cursor),
              !cursorHeld, !cursorPinned else { return nil }
        return go(.camera)
    }

    private var idleMode: ControlMode { !keymapUsesMouse || pauseForTextInput ? .cursor : .off }

    private mutating func go(_ target: ControlMode) -> ModeTransition? {
        guard target != mode else { return nil }
        let transition = ModeTransition(from: mode, to: target)
        mode = target
        if target == .camera || target == .editor || target == .textInput { cursorShownByPlayer = false }
        return transition
    }

    @discardableResult
    public mutating func keymapChanged(usesMouse: Bool, menuKeys: Set<String>? = nil,
                                      preserveMode: Bool = false) -> ModeTransition? {
        keymapUsesMouse = usesMouse
        if let menuKeys { self.menuKeys = menuKeys }
        // A gameplay layer key changes its bindings, never the player's camera/cursor choice.
        if preserveMode { return nil }
        if !usesMouse {
            cursorHeld = false
            cursorPinned = false
            if beforeTextInput == .camera { beforeTextInput = idleMode }
            if mode == .camera { return go(idleMode) }
        }
        // Preserve an open menu, editor and text input across context/map changes.
        guard usesMouse, behaviour == .hold, (mode == idleMode || mode == .cursor),
              !cursorHeld, !cursorPinned else { return nil }
        return go(.camera)
    }

    // MARK: Cursor key

    public mutating func cursorKeyPressed() -> ModeTransition? {
        if mode == .editor || mode == .textInput { return nil }
        switch behaviour {
        case .hold:
            guard mode == .camera || (mode == .cursor && keymapUsesMouse) else { return nil }
            cursorHeld = true
            cursorShownByPlayer = true
            // Menus closed with the mouse cannot report their state through a Unity UI.
            // Holding/releasing Option explicitly reclaims gameplay even after such a close.
            if mode == .cursor { return nil }
            return go(.cursor)
        case .toggle:
            // Upstream ModeAutomaton.onOption.
            switch mode {
            case .off where keymapUsesMouse:
                return go(.camera)
            case .cursor where keymapUsesMouse:
                return go(.camera)
            case .camera:
                let transition = go(idleMode)
                cursorShownByPlayer = true
                return transition
            default:
                return nil
            }
        }
    }

    /// A middle click (the scroll wheel pressed) toggles the cursor, whatever the cursor key's behaviour
    /// (2026-10-10, user request): one click shows it and keeps it, the next returns to the camera.
    public mutating func cursorClickToggled() -> ModeTransition? {
        guard keymapUsesMouse else { return nil }
        switch mode {
        case .camera:
            cursorHeld = false
            cursorPinned = true
            let transition = go(.cursor)
            cursorShownByPlayer = true
            return transition
        case .cursor, .off:
            cursorHeld = false
            cursorPinned = false
            return go(.camera)
        case .editor, .textInput:
            return nil
        }
    }

    public mutating func cursorKeyReleased() -> ModeTransition? {
        guard behaviour == .hold, cursorHeld else { return nil }
        cursorHeld = false
        cursorShownByPlayer = false
        guard mode == .cursor else { return nil }
        return go(keymapUsesMouse ? .camera : idleMode)
    }

    public mutating func resumeGameplay() -> ModeTransition? {
        guard keymapUsesMouse, mode != .editor, mode != .textInput else { return nil }
        cursorHeld = false
        cursorPinned = false
        return go(.camera)
    }

    // MARK: Text input

    public mutating func textInputBegan() -> ModeTransition? {
        guard pauseForTextInput, mode != .editor, mode != .textInput else { return nil }
        beforeTextInput = mode
        return go(.textInput)
    }

    public mutating func textInputEnded() -> ModeTransition? {
        guard mode == .textInput else { return nil }
        // Upstream always returned to the cursor; returning to where the user was is kinder
        // in hold mode, where camera mode is home.
        return go(behaviour == .hold ? beforeTextInput : .cursor)
    }

    // MARK: Editor

    public mutating func editorToggled(open: Bool) -> ModeTransition? {
        if open {
            return go(.editor)
        }
        guard mode == .editor else { return nil }
        cursorPinned = false
        // A pointer-only map must keep the cursor after editing.
        return go(keymapUsesMouse ? .camera : idleMode)
    }
}
