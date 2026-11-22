import Foundation
import MulgContracts

/// In-game hotkeys such as ⌥⌘U for the MetalFX layer (PLAN.md §5.2).
///
/// The controls module owns the keyboard and asks the hotkey centre first, so a module that
/// only needs one shortcut never has to touch keyboard handling.
@MainActor
public final class HotkeyCenter {
    public struct Registration {
        public let hotkey: Hotkey
        public let owner: ModuleID
        public let title: String
        let action: @MainActor () -> Void
    }

    public enum RegistrationError: Error, Equatable {
        case alreadyTaken(by: ModuleID)
    }

    public private(set) var registrations: [Hotkey: Registration] = [:]

    public init() {}

    public func register(
        _ hotkey: Hotkey,
        owner: ModuleID,
        title: String,
        action: @escaping @MainActor () -> Void
    ) throws(RegistrationError) {
        if let existing = registrations[hotkey], existing.owner != owner {
            throw .alreadyTaken(by: existing.owner)
        }
        registrations[hotkey] = Registration(hotkey: hotkey, owner: owner, title: title, action: action)
    }

    public func unregister(_ hotkey: Hotkey) {
        registrations[hotkey] = nil
    }

    /// Returns true when the key press was a hotkey and was handled. Key releases and
    /// auto-repeats of a hotkey are also swallowed, so the game never sees half of it.
    public func handle(keyCode: UInt16, modifiers: ModifierSet, isDown: Bool, isRepeat: Bool) -> Bool {
        if !isDown {
            // The modifiers may already be released, so match the release by key code alone.
            return swallowedKeys.remove(keyCode) != nil
        }
        // Releasing modifiers or unregistering the command does not turn a held
        // shortcut's auto-repeat into a new gameplay press.
        if isRepeat && swallowedKeys.contains(keyCode) { return true }
        // A key that began as gameplay cannot become a shortcut halfway through a hold
        // when modifiers change: swallowing its release would leave gameplay held.
        if isRepeat { return false }
        let hotkey = Hotkey(keyCode: keyCode, modifiers: modifiers.hotkeyRelevant)
        guard let registration = registrations[hotkey] else {
            // A hotkey's release can be lost (⌘ held, focus lost). This plain press is the game's,
            // so its release must reach the game too, or the key stays held there.
            swallowedKeys.remove(keyCode)
            return false
        }
        swallowedKeys.insert(keyCode)
        if !isRepeat {
            registration.action()
        }
        return true
    }

    /// Keys whose press was a hotkey, so their release is swallowed too.
    private var swallowedKeys: Set<UInt16> = []
}
