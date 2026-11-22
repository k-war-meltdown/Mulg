#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import Testing
@testable import MulgBridgeAppKit

@Suite("Native in-game commands", .serialized) @MainActor
struct GameCommandMenuTests {
    private func command(_ id: String = "controls.toggleEditor", key: String = "K",
                         section: String = "editor", submenu: String? = nil, checked: Bool = false) -> [String: Any] {
        var value: [String: Any] = ["id": id, "title": id, "key": key,
            "section": section, "checked": checked, "modifiers": ["command"]]
        if let submenu { value["submenu"] = submenu }
        return value
    }

    @Test("Editor menu has an enabled explicit target and keeps Cmd-K")
    func dispatch() throws {
        let root = NSMenu(), controller = GameCommandMenu()
        var performed: [String] = []
        controller.update([command()], title: "Controls", perform: { performed.append($0) }, in: root)
        let leaf = try #require(root.items.first?.submenu?.items.first)
        #expect(leaf.isEnabled && leaf.target === controller)
        #expect(leaf.keyEquivalent == "k" && leaf.keyEquivalentModifierMask == .command)
        let action = try #require(leaf.action)
        _ = controller.perform(action, with: leaf)
        #expect(performed == ["controls.toggleEditor"])
    }

    @Test("Late UIKit root replacements retain game menus and get one Controls menu")
    func rebuiltRoot() {
        let first = NSMenu(), second = NSMenu(), controller = GameCommandMenu()
        let game = NSMenuItem(title: "Game", action: nil, keyEquivalent: "")
        second.addItem(game)
        controller.update([command()], title: "Controls", perform: { _ in }, in: first)
        controller.reconcile(in: second)
        controller.reconcile(in: second)
        #expect(first.numberOfItems == 0)
        #expect(second.items.first === game)
        #expect(second.items.filter { $0.identifier == GameCommandMenu.identifier }.count == 1)
        controller.update([], title: "Controls", perform: { _ in }, in: second)
        #expect(second.items.count == 1 && second.items.first === game)
    }

    @Test("Profiles, checkmarks and editor shortcuts survive updates")
    func profiles() throws {
        let root = NSMenu(), controller = GameCommandMenu()
        controller.update([command(), command("profile", key: "", section: "profiles", submenu: "Profiles", checked: true)],
                          title: "Controls", perform: { _ in }, in: root)
        let menu = try #require(root.items.first?.submenu)
        #expect(menu.items[1].isSeparatorItem)
        let profile = try #require(menu.items.last?.submenu?.items.first)
        #expect(profile.state == .on && profile.keyEquivalent.isEmpty)
        controller.update([command(key: "UIKeyInputUpArrow")], title: "Controls", perform: { _ in }, in: root)
        #expect(root.numberOfItems == 1)
        #expect(root.items.first?.submenu?.items.first?.keyEquivalent == String(UnicodeScalar(NSUpArrowFunctionKey)!))
    }

    @Test("Registration before a native root exists is attached when it arrives")
    func lateRoot() {
        let controller = GameCommandMenu(), root = NSMenu()
        controller.update([command()], title: "Controls", perform: { _ in }, in: nil)
        controller.reconcile(in: root)
        #expect(root.items.first?.title == "Controls")
    }

    @Test("Same-root edits reconcile duplicates and silent removeAllItems without losing commands")
    func sameRootMutation() throws {
        let root = NSMenu(), controller = GameCommandMenu()
        controller.update([command()], title: "Controls", perform: { _ in }, in: root)
        let owned = try #require(root.items.first)
        for _ in 0..<100 { controller.reconcile(in: root) }
        #expect(root.items.first === owned)
        let duplicate = NSMenuItem(title: "Duplicate", action: nil, keyEquivalent: "")
        duplicate.identifier = GameCommandMenu.identifier
        root.addItem(duplicate)
        controller.reconcile(in: root)
        #expect(root.items.count == 1 && root.items.first === owned)
        root.removeAllItems() // AppKit explicitly omits per-item notifications here.
        controller.reconcile(in: root)
        #expect(root.items.first === owned)
        #expect(owned.submenu?.items.first?.target === controller)
    }
}
#endif
