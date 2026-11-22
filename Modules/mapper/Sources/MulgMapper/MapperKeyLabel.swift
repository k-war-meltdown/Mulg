import Foundation

/// How a binding is written on a control and in the panel. Keymaps name keys the way the Game
/// Controller framework does ("Lshft", "Spc", "cA"); players read "⇧", "Space", "A".
public enum MapperKeyLabel {
    private static let symbols: [String: (short: String, long: String)] = [
        "Lshft": ("⇧", "Left Shift"), "Rshft": ("⇧", "Right Shift"),
        "Spc": ("Space", "Space"), "Tab": ("⇥", "Tab"), "Caps": ("⇪", "Caps Lock"),
        "LCmd": ("⌘", "Left Command"), "RCmd": ("⌘", "Right Command"),
        "LOpt": ("⌥", "Left Option"), "ROpt": ("⌥", "Right Option"),
        "LCtrl": ("⌃", "Left Control"), "RCtrl": ("⌃", "Right Control"),
        "Enter": ("↩", "Return"), "Del": ("⌫", "Delete"), "Esc": ("Esc", "Escape"),
        "Left": ("←", "Left arrow"), "Right": ("→", "Right arrow"), "Up": ("↑", "Up arrow"), "Down": ("↓", "Down arrow"),
        "LMB": ("Click", "Left click"), "RMB": ("R-Click", "Right click"), "MMB": ("M-Click", "Middle click"),
        "Mouse": ("Mouse", "Mouse"),
        "Left Thumbstick": ("L-Stick", "Left stick"), "Right Thumbstick": ("R-Stick", "Right stick"),
        "cA": ("A", "Button A"), "cB": ("B", "Button B"), "cX": ("X", "Button X"), "cY": ("Y", "Button Y"),
        "dU": ("D↑", "D-pad up"), "dD": ("D↓", "D-pad down"), "dL": ("D←", "D-pad left"),
        "Controller": ("Pad", "Controller"),
        "Ctx Menu": ("Menu", "Context menu"), "Page Up": ("PgUp", "Page Up"), "Page Down": ("PgDn", "Page Down"),
        "Del Fwd": ("⌦", "Forward delete")
    ]

    /// The text shown on a control: short enough to fit a small circle.
    public static func short(_ name: String) -> String {
        if name.isEmpty { return "?" }
        if let known = symbols[name] { return known.short }
        if name.hasPrefix("Keypad ") { return "N" + name.dropFirst("Keypad ".count) }
        if name.hasPrefix("Button ") { return String(name.dropFirst("Button ".count)) }
        return name.count > 7 ? String(name.prefix(6)) + "…" : name
    }

    /// The text for the panel and for speech.
    public static func long(_ name: String) -> String {
        if name.isEmpty { return "nothing yet" }
        if let known = symbols[name] { return known.long }
        if name.hasPrefix("⌃") { return "Control + " + long(String(name.dropFirst())) }
        return name
    }
}
