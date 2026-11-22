#if os(macOS) && !targetEnvironment(macCatalyst)
import SwiftUI

/// The settings sidebar: seven pages in two groups (2026-10-10, user request: fewer, clearer pages).
/// A page with several parts shows them as tabs; each part keeps its own form and reset.
public enum GameSettingsPage: String, CaseIterable, Identifiable {
    case display, performance, background, controls, filesAndPrivacy, compatibility, startup

    public var id: String { rawValue }

    public enum Group: String, CaseIterable, Identifiable {
        case game = "Game", system = "System"
        public var id: String { rawValue }
        public var pages: [GameSettingsPage] { GameSettingsPage.allCases.filter { $0.group == self } }
    }

    public var group: Group {
        switch self {
        case .display, .performance, .background, .controls: .game
        case .filesAndPrivacy, .compatibility, .startup: .system
        }
    }

    /// Its parts, in tab order; the first opens with the page.
    public var sections: [GameSettingsSection] {
        switch self {
        case .display: [.display]
        case .performance: [.graphics, .unlocks]
        case .background: [.power, .sound]
        case .controls: [.controls, .keymapOptions]
        case .filesAndPrivacy: [.storage, .privacy]
        case .compatibility: [.device, .bypasses, .runtime]
        case .startup: [.startup, .debugging, .info]
        }
    }

    public init(_ section: GameSettingsSection) {
        self = Self.allCases.first { $0.sections.contains(section) } ?? .display
    }

    public var title: String {
        switch self {
        case .display: "Display & resolution"
        case .performance: "Performance & FPS"
        case .background: "Background, battery & sound"
        case .controls: "Controls"
        case .filesAndPrivacy: "Files & privacy"
        case .compatibility: "Compatibility"
        case .startup: "Startup & debugging"
        }
    }

    public var subtitle: String {
        switch self {
        case .display: "Resolution, window size and shape, and how the window behaves."
        case .performance: "Profiles, frame rate, MetalFX, the 120 FPS unlock and camera reach."
        case .background: "Playing in the background, on battery, when hot, and the sound format."
        case .controls: "Play mode, keymaps, mouse, controllers, and how keys reach the game."
        case .filesAndPrivacy: "Where the game's files are, save backups, saved logins and what the game may use."
        case .compatibility: "The device the game sees, compatibility fixes and Mulg's runtime."
        case .startup: "Launch options, plugins, Discord, debugging and bundle details."
        }
    }

    public var symbol: String {
        switch self {
        case .display: "display"
        case .performance: "speedometer"
        case .background: "battery.75percent"
        case .controls: "keyboard"
        case .filesAndPrivacy: "externaldrive"
        case .compatibility: "ipad.landscape"
        case .startup: "power"
        }
    }

    public var tint: Color { sections[0].tint }
}

extension GameSettingsSection {
    /// The tab label inside its page.
    public var tabTitle: String {
        switch self {
        case .display: "Display"
        case .graphics: "Graphics & frame rate"
        case .unlocks: "120 FPS & camera"
        case .power: "Background & battery"
        case .sound: "Sound"
        case .controls: "Controls"
        case .keymapOptions: "Keys & mouse"
        case .storage: "Files"
        case .privacy: "Privacy"
        case .device: "Device"
        case .bypasses: "Bypasses"
        case .runtime: "Runtime"
        case .startup: "Startup"
        case .debugging: "Debugging"
        case .info: "Info"
        }
    }
}
#endif
