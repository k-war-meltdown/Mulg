import Foundation

/// Key codes and names used in keymap files, ported unchanged from upstream
/// (Runtime/MulgKit/Keymap/KeyCodeNames.swift) so existing keymaps keep working.
///
/// Keys use Game Controller key codes, which are HID usage IDs. Mouse and controller buttons
/// use negative codes. The raw HID values are written out here instead of using
/// `GCKeyCode`, so this file has no framework dependency.
public enum KeymapKeyNames {
    public static let defaultCode = -10

    public static let leftMouseButton = "LMB"
    public static let rightMouseButton = "RMB"
    public static let middleMouseButton = "MMB"
    public static let mouseMove = "Mouse"

    // Internal names, never stored in keymaps.
    public static let scrollWheelScale = "ScrollWheelScale"
    public static let scrollWheelDrag = "ScrollWheelDrag"
    public static let fakeMouse = "FakeMouse"

    public static let leftMouseCode = -1
    public static let rightMouseCode = -2
    public static let middleMouseCode = -3

    /// Code → name, as shown on keymap buttons.
    public static let keyCodes: [Int: String] = [
        -4: "cA", -5: "cX", -6: "cB", -7: "cY", -8: "dU", -9: "dD", -10: "Controller", -11: "dL",
        -12: "L1", -13: "L2", -14: "R1", -15: "R2", -1: "LMB", -2: "RMB", -3: "MMB",
        41: "Esc", 44: "Spc", 225: "Lshft", 57: "Caps", 43: "Tab", 227: "LCmd", 226: "LOpt",
        224: "LCtrl", 228: "RCtrl", 231: "RCmd", 230: "ROpt", 40: "Enter", 42: "Del", 229: "Rshft",
        80: "Left", 79: "Right", 82: "Up", 81: "Down",
        58: "F1", 59: "F2", 60: "F3", 61: "F4", 62: "F5", 63: "F6", 64: "F7", 65: "F8", 66: "F9",
        67: "F10", 68: "F11", 69: "F12",
        30: "1", 31: "2", 32: "3", 33: "4", 34: "5", 35: "6", 36: "7", 37: "8", 38: "9", 39: "0",
        45: "-", 46: "=", 20: "Q", 26: "W", 8: "E", 21: "R", 23: "T", 28: "Y", 24: "U", 12: "I",
        18: "O", 19: "P", 47: "[", 48: "]", 4: "A", 22: "S", 7: "D", 9: "F", 10: "G", 11: "H",
        13: "J", 14: "K", 15: "L", 51: ";", 52: "'", 49: "\\", 29: "Z", 53: "`", 27: "X", 6: "C",
        25: "V", 5: "B", 17: "N", 16: "M", 54: ",", 55: ".", 56: "/",
        // Upstream adds these through GCKeyCode; HID usage values written out.
        108: "F17", 99: "Keypad .", 85: "Keypad *", 87: "Keypad +", 83: "NumLock", 84: "Keypad /",
        88: "Keypad Enter", 86: "Keypad -", 109: "F18", 110: "F19", 103: "Keypad =",
        98: "Keypad 0", 89: "Keypad 1", 90: "Keypad 2", 91: "Keypad 3", 92: "Keypad 4",
        93: "Keypad 5", 94: "Keypad 6", 95: "Keypad 7", 111: "F20", 96: "Keypad 8", 97: "Keypad 9",
        137: "¥", 135: "ろ", 100: "§", 50: "Keypad ,", 145: "英数 한자", 144: "かな 한/영",
        104: "F13", 107: "F16", 105: "F14", 101: "Ctx Menu", 106: "F15", 73: "Help", 74: "Home",
        75: "Page Up", 76: "Del Fwd", 77: "End", 78: "Page Down"
    ]

    /// macOS virtual key code (`NSEvent.keyCode`) → Game Controller key code.
    public static let virtualToKeymapCode: [UInt16: Int] = [
        0: 4, 1: 22, 2: 7, 3: 9, 4: 11, 5: 10, 6: 29, 7: 27, 8: 6, 9: 25, 11: 5, 12: 20, 13: 26,
        14: 8, 15: 21, 16: 28, 17: 23, 18: 30, 19: 31, 20: 32, 21: 33, 22: 35, 23: 34, 24: 46,
        25: 38, 26: 36, 27: 45, 28: 37, 29: 39, 30: 48, 31: 18, 32: 24, 33: 47, 34: 12, 35: 19,
        36: 40, 37: 15, 38: 13, 39: 52, 40: 14, 41: 51, 42: 49, 43: 54, 44: 56, 45: 17, 46: 16,
        47: 55, 48: 43, 49: 44, 50: 53, 51: 42, 53: 41, 54: 231, 55: 227, 56: 225, 57: 57,
        58: 226, 59: 224, 60: 229, 61: 230, 62: 228, 96: 62, 97: 63, 98: 64, 99: 60, 100: 65,
        101: 66, 103: 68, 109: 67, 111: 69, 118: 61, 120: 59, 122: 58, 123: 80, 124: 79,
        125: 81, 126: 82,
        // Upstream adds these through GCKeyCode; HID usage values written out.
        10: 100, 64: 108, 65: 99, 67: 85, 69: 87, 71: 83, 75: 84, 76: 88, 78: 86, 79: 109,
        80: 110, 81: 103, 82: 98, 83: 89, 84: 90, 85: 91, 86: 92, 87: 93, 88: 94, 89: 95,
        90: 111, 91: 96, 92: 97, 93: 137, 94: 135, 95: 50, 102: 145, 104: 144, 105: 104,
        106: 107, 107: 105, 110: 101, 113: 106, 114: 73, 115: 74, 116: 75, 117: 76, 119: 77,
        121: 78
    ]

    public static func name(forKeyCode code: Int) -> String? {
        keyCodes[code]
    }

    /// The keymap name for a macOS key press, as actions register it.
    public static func name(forVirtualKeyCode code: UInt16) -> String? {
        virtualToKeymapCode[code].flatMap { keyCodes[$0] }
    }

    public static func keymapCode(forVirtualKeyCode code: UInt16) -> Int? {
        virtualToKeymapCode[code]
    }

    /// Mouse button index from AppKit (0 left, 1 right, 2 middle) → keymap name, as upstream's
    /// EditorMouseEventAdapter.getMouseButtonName: extra buttons are "MBtn<n>".
    public static func name(forMouseButton button: Int) -> String {
        switch button {
        case 0: leftMouseButton
        case 1: rightMouseButton
        case 2: middleMouseButton
        default: "MBtn\(button)"
        }
    }

    /// Mouse button index → keymap code (negative), for controller bindings.
    public static func code(forMouseButton button: Int) -> Int? {
        switch button {
        case 0: leftMouseCode
        case 1: rightMouseCode
        case 2: middleMouseCode
        default: nil
        }
    }

    /// Names of analog joysticks other than the mouse.
    public static let thumbstickNames: Set<String> = ["Left Thumbstick", "Right Thumbstick"]
}
