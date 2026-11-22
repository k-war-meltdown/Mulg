import Foundation
import MulgKeymaps

/// What a player can place with the mapper: the four kinds of control the keymap format knows,
/// named the way a player thinks of them.
public enum MapperTool: String, Sendable, CaseIterable, Equatable {
    case joystick, floatingJoystick, skill, camera, drag

    public var title: String {
        switch self {
        case .joystick: "Joystick"
        case .floatingJoystick: "Floating joystick"
        case .skill: "Skill button"
        case .camera: "Camera"
        case .drag: "Drag"
        }
    }

    /// One line under the title in the picker.
    public var subtitle: String {
        switch self {
        case .joystick: "W A S D on a stick that stays in place"
        case .floatingJoystick: "W A S D on a stick that appears where you touch"
        case .skill: "Press a key to tap here"
        case .camera: "Look around with the mouse"
        case .drag: "Hold a key, move the mouse"
        }
    }

    /// SF Symbol name.
    public var symbol: String {
        switch self {
        case .joystick: "dpad"
        case .floatingJoystick: "dpad.fill"
        case .skill: "circle.circle"
        case .camera: "computermouse"
        case .drag: "hand.draw"
        }
    }

    var newElement: KeymapEditorModel.NewElement {
        switch self {
        case .joystick: .joystick
        case .floatingJoystick: .floatingJoystick
        case .skill: .button
        case .camera: .cameraArea
        case .drag: .draggableButton
        }
    }

    /// Whether the control has no key until the player presses one. Joysticks start on W A S D and
    /// a camera on the mouse; a skill button or drag area starts empty and is discarded when the
    /// player clicks away without binding it.
    public var startsUnbound: Bool {
        self == .skill || self == .drag
    }
}
