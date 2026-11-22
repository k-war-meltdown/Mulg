import Foundation
import MulgContracts
@testable import MulgEngine
import Testing

@Suite("Menu centre") @MainActor
struct MenuCenterTests {
    @Test("Native menu callbacks dispatch current commands and follow profile/editor changes")
    func nativeMenu() throws {
        let menus = MenuCenter(), bridge = StartupAudioBridge()
        var opened = 0
        try menus.register(MenuCommand(id: "editor", title: "Edit Controls…", key: "K", section: "editor"),
                           owner: .controls) { opened += 1 }
        #expect(menus.installNative(bridge: bridge))
        #expect(bridge.menuTitle == "Controls")
        #expect(bridge.gameMenus.last?.first?["id"] as? String == "editor")
        bridge.menuAction?("editor")
        #expect(opened == 1)
        try menus.register(MenuCommand(id: "profile", title: "Default", key: "", section: "profiles",
                                       submenu: "Profiles", isChecked: true), owner: .controls) {}
        let command = try #require(bridge.gameMenus.last?.last)
        #expect(command["checked"] as? Bool == true)
        #expect(command["submenu"] as? String == "Profiles")
        menus.unregister("editor")
        bridge.menuAction?("editor") // a stale native item cannot invoke a removed command
        #expect(opened == 1)
        menus.unregister("profile")
        #expect(bridge.gameMenus.last?.isEmpty == true)
    }

    @Test("Native-menu absence leaves the UIKit fallback available")
    func missingNativeMenu() {
        #expect(!MenuCenter().installNative(bridge: nil))
    }

    @Test("Native metadata preserves shortcut modifiers and section order")
    func nativeMetadata() throws {
        let menus = MenuCenter()
        try menus.register(MenuCommand(id: "editor", title: "Edit", key: "K", section: "editor"), owner: .controls) {}
        try menus.register(MenuCommand(id: "rotation", title: "Rotate", key: "1", modifiers: [.command, .shift],
                                       section: "display", submenu: "Rotation"), owner: .display) {}
        try menus.register(MenuCommand(id: "save", title: "Save", key: "S", section: "editor"), owner: .controls) {}
        #expect(menus.nativeCommands.compactMap { $0["id"] as? String } == ["editor", "save", "rotation"])
        #expect(menus.nativeCommands.last?["modifiers"] as? [String] == ["command", "shift"])
    }

    @Test("Commands run their action by ID")
    func perform() throws {
        let menus = MenuCenter()
        var ran = 0
        try menus.register(MenuCommand(id: "controls.toggleEditor", title: "Editor", key: "K", section: "editor"),
                           owner: .controls) { ran += 1 }
        #expect(menus.perform("controls.toggleEditor"))
        #expect(!menus.perform("missing"))
        #expect(ran == 1)
    }

    @Test("Two modules can't use the same ID or shortcut")
    func clashes() throws {
        let menus = MenuCenter()
        try menus.register(MenuCommand(id: "a", title: "A", key: "K", section: "s"), owner: .controls) {}
        #expect(throws: MenuCenter.RegistrationError.idTaken(by: .controls)) {
            try menus.register(MenuCommand(id: "a", title: "A", key: "L", section: "s"), owner: .display) {}
        }
        #expect(throws: MenuCenter.RegistrationError.shortcutTaken(by: "a")) {
            try menus.register(MenuCommand(id: "b", title: "B", key: "k", section: "s"), owner: .display) {}
        }
        // Same key with other modifiers is fine.
        try menus.register(MenuCommand(id: "c", title: "C", key: "K", modifiers: [.command, .shift], section: "s"),
                           owner: .display) {}
    }

    @Test("Layout groups sections and submenus in registration order")
    func layout() throws {
        let menus = MenuCenter()
        try menus.register(MenuCommand(id: "e", title: "Editor", key: "K", section: "editor"), owner: .controls) {}
        for index in 0..<2 {
            try menus.register(MenuCommand(id: "r\(index)", title: "R\(index)", key: "\(index + 1)", modifiers: [.command, .shift],
                                           section: "display", submenu: "Rotate"), owner: .display) {}
        }
        try menus.register(MenuCommand(id: "d", title: "Delete", key: MenuCommand.Key.delete, section: "editor"), owner: .controls) {}
        let layout = menus.layout()
        #expect(layout.sections.map(\.name) == ["editor", "display"])
        #expect(layout.sections[0].commands.map(\.id) == ["e", "d"])
        #expect(layout.sections[1].submenus.first?.commands.map(\.id) == ["r0", "r1"])
    }

    @Test("Shortcut descriptions")
    func descriptions() {
        #expect(MenuCommand(id: "a", title: "", key: "k", section: "").shortcutDescription == "⌘K")
        #expect(MenuCommand(id: "a", title: "", key: "1", modifiers: [.command, .shift], section: "").shortcutDescription == "⇧⌘1")
        #expect(MenuCommand(id: "a", title: "", key: MenuCommand.Key.delete, section: "").shortcutDescription == "⌘⌫")
    }

    @Test("The menu is called Controls")
    func title() {
        #expect(MenuCenter().title == "Controls")
    }

    @Test("Commands without a shortcut never clash, and keep their checkmark and submenu")
    func noShortcut() throws {
        let menus = MenuCenter()
        for index in 0..<3 {
            try menus.register(MenuCommand(id: "p\(index)", title: "Profile \(index)", key: "", section: "profiles",
                                           submenu: "Profiles", isChecked: index == 1), owner: .controls) {}
        }
        try menus.register(MenuCommand(id: "k", title: "K", key: "K", section: "profiles"), owner: .controls) {}
        let section = try #require(menus.layout().sections.first)
        #expect(section.submenus.first?.title == "Profiles")
        #expect(section.submenus.first?.commands.map(\.isChecked) == [false, true, false])
        #expect(menus.commands.first { $0.id == "p0" }?.shortcutDescription == "")
        // A shortcut can still be used once, and replacing a command by ID changes it in place.
        try menus.register(MenuCommand(id: "p1", title: "Profile 1", key: "", section: "profiles", submenu: "Profiles"), owner: .controls) {}
        #expect(menus.commands.filter { $0.id == "p1" }.count == 1)
        #expect(menus.commands.first { $0.id == "p1" }?.isChecked == false)
        // In place means in its place too: a re-registered command no longer jumps to the end.
        #expect(menus.commands.map(\.id) == ["p0", "p1", "p2", "k"])
    }
}
