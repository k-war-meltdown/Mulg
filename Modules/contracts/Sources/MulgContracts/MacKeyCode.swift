import Foundation

/// macOS virtual key codes (the values in `NSEvent.keyCode`), shared by hotkeys and keymaps.
public enum MacKeyCode {
    public static let byName: [String: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
        "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
        "[": 0x21, "i": 0x22, "p": 0x23, "return": 0x24, "l": 0x25, "j": 0x26, "'": 0x27,
        "k": 0x28, ";": 0x29, "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F,
        "tab": 0x30, "space": 0x31, "`": 0x32, "delete": 0x33, "escape": 0x35,
        "command": 0x37, "shift": 0x38, "capslock": 0x39, "option": 0x3A, "control": 0x3B,
        "rightcommand": 0x36, "rightshift": 0x3C, "rightoption": 0x3D, "rightcontrol": 0x3E,
        "function": 0x3F,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62,
        "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79, "forwarddelete": 0x75
    ]

    public static let nameByCode: [UInt16: String] = {
        var names: [UInt16: String] = [:]
        for (name, code) in byName {
            names[code] = name
        }
        return names
    }()

    public static func code(named name: String) -> UInt16? {
        byName[name.lowercased()]
    }

    /// Modifier keys and the flag each one sets, for turning flags-changed events into
    /// key presses and releases.
    public static func modifier(for keyCode: UInt16) -> ModifierSet? {
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
}

/// Modifier keys, independent of AppKit so both processes can use it.
public struct ModifierSet: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let command = ModifierSet(rawValue: 1 << 0)
    public static let option = ModifierSet(rawValue: 1 << 1)
    public static let control = ModifierSet(rawValue: 1 << 2)
    public static let shift = ModifierSet(rawValue: 1 << 3)
    public static let capsLock = ModifierSet(rawValue: 1 << 4)
    public static let function = ModifierSet(rawValue: 1 << 5)

    /// Builds the set from `NSEvent.ModifierFlags.rawValue` without importing AppKit.
    public init(appKitFlags raw: UInt) {
        var set: ModifierSet = []
        if raw & (1 << 16) != 0 { set.insert(.capsLock) }
        if raw & (1 << 17) != 0 { set.insert(.shift) }
        if raw & (1 << 18) != 0 { set.insert(.control) }
        if raw & (1 << 19) != 0 { set.insert(.option) }
        if raw & (1 << 20) != 0 { set.insert(.command) }
        if raw & (1 << 23) != 0 { set.insert(.function) }
        self = set
    }

    /// The modifiers that matter for hotkeys (Caps Lock and Fn are ignored).
    public var hotkeyRelevant: ModifierSet {
        intersection([.command, .option, .control, .shift])
    }
}

/// A key plus modifiers, parsed from settings strings such as "option+command+U".
public struct Hotkey: Hashable, Sendable, CustomStringConvertible {
    public let keyCode: UInt16
    public let modifiers: ModifierSet

    public init(keyCode: UInt16, modifiers: ModifierSet) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public init?(_ text: String) {
        var modifiers: ModifierSet = []
        var key: UInt16?
        for part in text.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "command", "cmd", "⌘": modifiers.insert(.command)
            case "option", "alt", "opt", "⌥": modifiers.insert(.option)
            case "control", "ctrl", "⌃": modifiers.insert(.control)
            case "shift", "⇧": modifiers.insert(.shift)
            default:
                guard key == nil, let code = MacKeyCode.code(named: part) else { return nil }
                key = code
            }
        }
        guard let key else { return nil }
        self.init(keyCode: key, modifiers: modifiers)
    }

    public var description: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append((MacKeyCode.nameByCode[keyCode] ?? "key \(keyCode)").uppercased())
        return parts.joined()
    }
}
