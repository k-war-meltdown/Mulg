import Foundation
import MulgContracts
import MulgBridge

/// A command a module puts in the menu bar, such as "Edit Controls… ⌘K".
public struct MenuCommand: Sendable, Equatable {
    /// Unique, namespaced like settings: "controls.toggleEditor".
    public let id: String
    public let title: String
    /// SF Symbol name.
    public let symbol: String?
    /// The key: a character ("K"), or one of `MenuCommand.Key`. Empty for a command with no shortcut.
    public let key: String
    public let modifiers: ModifierSet
    /// Commands with the same section are grouped between separators.
    public let section: String
    /// Commands with a submenu title are placed in that submenu ("Rotate display area").
    public let submenu: String?
    /// Shown with a checkmark: the current choice in a list of profiles.
    public let isChecked: Bool

    public init(id: String, title: String, symbol: String? = nil, key: String, modifiers: ModifierSet = .command,
                section: String, submenu: String? = nil, isChecked: Bool = false) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.key = key
        self.modifiers = modifiers
        self.section = section
        self.submenu = submenu
        self.isChecked = isChecked
    }

    /// Special keys, spelled the way UIKit's `UIKeyCommand.input…` constants are.
    public enum Key {
        public static let delete = "\u{8}"
        public static let upArrow = "UIKeyInputUpArrow"
        public static let downArrow = "UIKeyInputDownArrow"
        public static let leftArrow = "UIKeyInputLeftArrow"
        public static let rightArrow = "UIKeyInputRightArrow"
        public static let escape = "UIKeyInputEscape"
    }

    /// "⌘K", "⇧⌘1": for notices and the Modules page.
    public var shortcutDescription: String {
        if key.isEmpty { return "" }
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case Key.delete: text += "⌫"
        case Key.upArrow: text += "↑"
        case Key.downArrow: text += "↓"
        case Key.leftArrow: text += "←"
        case Key.rightArrow: text += "→"
        case Key.escape: text += "⎋"
        default: text += key.uppercased()
        }
        return text
    }
}

/// The in-game menu (upstream `MenuController`): modules register commands, the engine builds
/// the menu. Upstream built it from a hook on a private UIKit initialiser; this uses the
/// public main-menu API, so the menu no longer depends on a private class (§12 #17).
@MainActor
public final class MenuCenter {
    public enum RegistrationError: Error, Equatable {
        case idTaken(by: ModuleID)
        case shortcutTaken(by: String)
    }

    struct Entry {
        let command: MenuCommand
        let owner: ModuleID
        let action: @MainActor () -> Void
    }

    /// Title of the top-level menu. It was "Keymapping" in upstream; it now holds only the controls
    /// and profile commands, so it is called "Controls".
    public let title: String
    private(set) var entries: [Entry] = []
    /// Called when the commands change after the menu was built, to rebuild it.
    var onChange: (@MainActor () -> Void)?

    public init(title: String = "Controls") {
        self.title = title
    }

    public func register(_ command: MenuCommand, owner: ModuleID,
                         action: @escaping @MainActor () -> Void) throws(RegistrationError) {
        if let existing = entries.first(where: { $0.command.id == command.id }), existing.owner != owner {
            throw .idTaken(by: existing.owner)
        }
        // A command without a shortcut can't clash with another one.
        if !command.key.isEmpty, let clash = entries.first(where: {
            $0.command.id != command.id && $0.command.key.lowercased() == command.key.lowercased()
                && $0.command.modifiers == command.modifiers
        }) {
            throw .shortcutTaken(by: clash.command.id)
        }
        // Re-registering (a checkmark that changed) keeps the command's place: it used to move to the end,
        // so a toggled item, and with it its whole section, jumped around the menu.
        let entry = Entry(command: command, owner: owner, action: action)
        if let index = entries.firstIndex(where: { $0.command.id == command.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        onChange?()
    }

    public func unregister(_ id: String) {
        entries.removeAll { $0.command.id == id }
        onChange?()
    }

    public var commands: [MenuCommand] { entries.map(\.command) }

    /// Native targets survive games that omit or replace the UIKit main menu.
    @discardableResult
    public func installNative(bridge: (any MacBridge)?) -> Bool {
        guard let bridge, bridge.installGameMenu != nil else { return false }
        bridge.installGameMenu?(nativeCommands, title: title) { [weak self] id in self?.perform(id) }
        onChange = { [weak self, weak bridge] in
            guard let self, let bridge else { return }
            bridge.installGameMenu?(self.nativeCommands, title: self.title) { [weak self] id in self?.perform(id) }
        }
        return true
    }

    var nativeCommands: [[String: Any]] {
        layout().sections.flatMap { section in
            (section.commands + section.submenus.flatMap(\.commands)).map { command in
                var modifiers: [String] = []
                if command.modifiers.contains(.command) { modifiers.append("command") }
                if command.modifiers.contains(.option) { modifiers.append("option") }
                if command.modifiers.contains(.control) { modifiers.append("control") }
                if command.modifiers.contains(.shift) { modifiers.append("shift") }
                var value: [String: Any] = ["id": command.id, "title": command.title, "key": command.key,
                    "modifiers": modifiers, "section": command.section, "checked": command.isChecked]
                if let submenu = command.submenu { value["submenu"] = submenu }
                if let symbol = command.symbol { value["symbol"] = symbol }
                return value
            }
        }
    }

    /// Runs a command's action. Returns false for an unknown ID.
    @discardableResult
    public func perform(_ id: String) -> Bool {
        guard let entry = entries.first(where: { $0.command.id == id }) else { return false }
        entry.action()
        return true
    }

    /// The menu's layout: sections in registration order, each with its plain commands and
    /// its submenus.
    struct Layout: Equatable {
        struct Section: Equatable {
            let name: String
            var commands: [MenuCommand] = []
            var submenus: [(title: String, commands: [MenuCommand])] = []

            static func == (lhs: Section, rhs: Section) -> Bool {
                lhs.name == rhs.name && lhs.commands == rhs.commands
                    && lhs.submenus.map(\.title) == rhs.submenus.map(\.title)
                    && lhs.submenus.map(\.commands) == rhs.submenus.map(\.commands)
            }
        }
        var sections: [Section] = []
    }

    func layout() -> Layout {
        var layout = Layout()
        for command in commands {
            var index = layout.sections.firstIndex { $0.name == command.section }
            if index == nil {
                layout.sections.append(Layout.Section(name: command.section))
                index = layout.sections.count - 1
            }
            guard let index else { continue }
            if let submenu = command.submenu {
                if let existing = layout.sections[index].submenus.firstIndex(where: { $0.title == submenu }) {
                    layout.sections[index].submenus[existing].commands.append(command)
                } else {
                    layout.sections[index].submenus.append((submenu, [command]))
                }
            } else {
                layout.sections[index].commands.append(command)
            }
        }
        return layout
    }
}

#if canImport(UIKit) && !os(watchOS)
import UIKit

extension MenuCenter {
    /// The centre whose commands the menu currently shows.
    static weak var installed: MenuCenter?

    /// Builds the menu now and whenever commands change. Call once the first scene is active:
    /// the main menu can't be configured while UIKit is building it.
    public func install(bridge: (any MacBridge)? = nil) {
        if installNative(bridge: bridge) { return }
        MenuCenter.installed = self
        UIMainMenuSystem.shared.setBuildConfiguration(UIMainMenuSystem.Configuration()) { builder in
            MainActor.assumeIsolated {
                MenuCenter.installed?.build(into: builder)
            }
        }
        onChange = {
            UIMenuSystem.main.setNeedsRebuild()
        }
    }

    func build(into builder: any UIMenuBuilder) {
        let identifier = UIMenu.Identifier("io.mulg.menu")
        builder.remove(menu: identifier)
        guard !entries.isEmpty else { return }
        let children: [UIMenuElement] = layout().sections.map { section in
            let plain: [UIMenuElement] = section.commands.map(Self.keyCommand)
            let submenus: [UIMenuElement] = section.submenus.map { submenu in
                UIMenu(title: submenu.title, children: submenu.commands.map(Self.keyCommand))
            }
            return UIMenu(title: "", options: .displayInline, children: plain + submenus)
        }
        let menu = UIMenu(title: title, identifier: identifier, children: children)
        // Games may remove standard menus; put it after View, else before Window, else last.
        if builder.menu(for: .view) != nil {
            builder.insertSibling(menu, afterMenu: .view)
        } else if builder.menu(for: .window) != nil {
            builder.insertSibling(menu, beforeMenu: .window)
        } else {
            builder.insertChild(menu, atEndOfMenu: .root)
        }
    }

    static let commandKey = "mulg.command"

    static func keyCommand(_ command: MenuCommand) -> UICommand {
        let image = command.symbol.flatMap { UIImage(systemName: $0) }
        let action = #selector(UIApplication.mulg_performMenuCommand(_:))
        let properties = [commandKey: command.id]
        let item: UICommand
        if command.key.isEmpty {
            item = UICommand(title: command.title, image: image, action: action, propertyList: properties)
        } else {
            item = UIKeyCommand(title: command.title, image: image, action: action, input: keyInput(command.key),
                                modifierFlags: flags(command.modifiers), propertyList: properties)
        }
        item.state = command.isChecked ? .on : .off
        return item
    }

    /// A letter goes to UIKit in lowercase, with Shift only in the modifier flags: an uppercase key
    /// equivalent can be read as Shift already held, so "K" with ⌘ became ⇧⌘K and "J" with ⌘ collided with
    /// "J" with ⇧⌘. Special keys (`MenuCommand.Key`) and digits pass unchanged; the menu shows letters uppercase.
    static func keyInput(_ key: String) -> String {
        key.count == 1 && key.allSatisfy(\.isLetter) ? key.lowercased() : key
    }

    static func flags(_ modifiers: ModifierSet) -> UIKeyModifierFlags {
        var flags: UIKeyModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.option) { flags.insert(.alternate) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        return flags
    }
}

extension UIApplication {
    /// The one action every Mulg menu item sends; the item's property list says which command.
    /// Prefixed so it can't clash with a method the game adds to UIApplication.
    @objc(mulg_performMenuCommand:)
    func mulg_performMenuCommand(_ sender: UICommand) {
        guard let id = (sender.propertyList as? [String: Any])?[MenuCenter.commandKey] as? String else { return }
        MenuCenter.installed?.perform(id)
    }
}
#endif
