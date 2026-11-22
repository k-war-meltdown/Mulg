import Foundation
import MulgContracts

// The seam between the controls module and whatever shows the control editor. Game-side modules
// may not import each other (PLAN.md §1.5 rule 2), so the controls module hosts an editor through
// this protocol and the mapper module supplies one through `ModuleContext.controlEditor`.
// Without a mapper, controls uses its own built-in editor.

/// One of the game's control profiles: a keymap file.
public struct ControlProfile: Sendable, Equatable, Identifiable {
    public let name: String
    public let isActive: Bool
    /// Buttons, joysticks and camera areas in the profile, base layer and layers together.
    public let controlCount: Int
    public var id: String { name }

    public init(name: String, isActive: Bool, controlCount: Int) {
        self.name = name
        self.isActive = isActive
        self.controlCount = controlCount
    }
}

/// Why a profile change did not happen, in words for the player.
public struct ControlProfileError: Error, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// What the controls module offers an open editor: the profiles, and ways to change them. Every
/// call keeps the files on disk safe: a profile is backed up before it is overwritten, a new
/// profile never replaces an old one, and an unreadable profile is never overwritten.
@MainActor
public final class ControlEditingHost {
    /// The game's profiles, the active one marked.
    public var profiles: () -> [ControlProfile]
    /// Makes `name` the active profile and returns what it holds. `saving` is the editor's
    /// unsaved draft of the profile being left: written to it first, or dropped when nil.
    public var switchProfile: (_ name: String, _ saving: KeymappingData?) -> Result<KeymappingData, ControlProfileError>
    /// Creates a new profile, makes it active and returns its final name and contents. `blank`
    /// starts empty, otherwise `keymap` is copied. `saving` is as for `switchProfile`.
    public var createProfile: (_ name: String, _ keymap: KeymappingData?, _ saving: KeymappingData?)
        -> Result<(name: String, keymap: KeymappingData), ControlProfileError>
    /// Ends the session: the editor's draft is written to the active profile when `save`, and
    /// gameplay controls resume.
    public var finish: (_ save: Bool) -> Void

    public init(
        profiles: @escaping () -> [ControlProfile] = { [] },
        switchProfile: @escaping (String, KeymappingData?) -> Result<KeymappingData, ControlProfileError> = { _, _ in
            .failure(ControlProfileError("Profiles are unavailable."))
        },
        createProfile: @escaping (String, KeymappingData?, KeymappingData?)
            -> Result<(name: String, keymap: KeymappingData), ControlProfileError> = { _, _, _ in
            .failure(ControlProfileError("Profiles are unavailable."))
        },
        finish: @escaping (Bool) -> Void = { _ in }
    ) {
        self.profiles = profiles
        self.switchProfile = switchProfile
        self.createProfile = createProfile
        self.finish = finish
    }
}

/// An editor for the game's controls. The input router sends it keys and mouse buttons while it
/// is open (`KeymapEditorInput`), and the controls module opens, closes and saves through it.
@MainActor
public protocol ControlEditing: KeymapEditorInput {
    var isOpen: Bool { get }
    /// The draft being edited; nil when closed.
    var model: KeymapEditorModel? { get }
    /// Opens the editor over the game. Returns false when there is nothing to show it on.
    func open(keymap: KeymappingData, profile: String, host: ControlEditingHost) -> Bool
    /// Shows another profile's keymap in an open editor.
    func replace(keymap: KeymappingData, profile: String)
    /// Closes the editor and returns the draft, and whether it changed.
    func close() -> (keymap: KeymappingData, changed: Bool)?
    /// A controller element was pressed or moved ("Button A", "Left Thumbstick").
    func controllerElement(_ name: String)
    // Commands the built-in editor offers as menu shortcuts.
    func removeSelected()
    func resizeSelected(larger: Bool)
    func toggleJoystickMode()
    func toggleButtonHold()
    func showLayer(offset: Int)
    func addLayer()
}
