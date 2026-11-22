#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// Owns only Mulg's menu. Converted games may replace the native root after activation.
@MainActor
final class GameCommandMenu: NSObject {
    static let identifier = NSUserInterfaceItemIdentifier("io.mulg.menu")
    private var item: NSMenuItem?
    private var perform: ((String) -> Void)?
    private weak var observedRoot: NSMenu?
    private var rootObservers: [any NSObjectProtocol] = []
    private var rootChanged = true

    isolated deinit {
        for observer in rootObservers { NotificationCenter.default.removeObserver(observer) }
    }

    private func observe(_ root: NSMenu?) {
        guard observedRoot !== root else { return }
        for observer in rootObservers { NotificationCenter.default.removeObserver(observer) }
        rootObservers.removeAll()
        observedRoot = root
        rootChanged = true
        guard let root else { return }
        for name in [NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification, NSMenu.didChangeItemNotification] {
            rootObservers.append(NotificationCenter.default.addObserver(forName: name, object: root, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rootChanged = true }
            })
        }
    }

    func update(_ commands: [[String: Any]], title: String, perform: @escaping (String) -> Void,
                in root: NSMenu?) {
        if let item, let oldRoot = item.menu { oldRoot.removeItem(item) }
        item = nil
        self.perform = perform
        guard !commands.isEmpty else { observe(nil); return }
        let menu = NSMenu(title: title)
        // Explicit targets keep the game's UIKit responder validation from disabling commands.
        menu.autoenablesItems = false
        var section: String?
        var submenus: [String: NSMenu] = [:]
        for command in commands {
            guard let id = command["id"] as? String, let title = command["title"] as? String,
                  let key = command["key"] as? String else { continue }
            let nextSection = command["section"] as? String ?? ""
            if nextSection != section {
                if section != nil { menu.addItem(.separator()) }
                section = nextSection
                submenus = [:]
            }
            let target: NSMenu
            if let name = command["submenu"] as? String {
                if let existing = submenus[name] { target = existing }
                else {
                    let submenu = NSMenu(title: name)
                    submenu.autoenablesItems = false
                    let parent = NSMenuItem(title: name, action: nil, keyEquivalent: "")
                    parent.submenu = submenu
                    menu.addItem(parent)
                    submenus[name] = submenu
                    target = submenu
                }
            } else { target = menu }
            let leaf = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: Self.keyEquivalent(key))
            leaf.target = self
            leaf.representedObject = id
            let modifiers = command["modifiers"] as? [String] ?? []
            leaf.keyEquivalentModifierMask = []
            if modifiers.contains("command") { leaf.keyEquivalentModifierMask.insert(.command) }
            if modifiers.contains("option") { leaf.keyEquivalentModifierMask.insert(.option) }
            if modifiers.contains("control") { leaf.keyEquivalentModifierMask.insert(.control) }
            if modifiers.contains("shift") { leaf.keyEquivalentModifierMask.insert(.shift) }
            leaf.state = command["checked"] as? Bool == true ? .on : .off
            if let symbol = command["symbol"] as? String { leaf.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            target.addItem(leaf)
        }
        guard menu.numberOfItems > 0 else { return }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.identifier = Self.identifier
        item.submenu = menu
        self.item = item
        reconcile(in: root)
    }

    func reconcile(in root: NSMenu?) {
        guard let root, let item else { return }
        observe(root)
        // didUpdate fires after input events. Unchanged roots need no array copy or scan.
        if item.menu === root, !rootChanged { return }
        if item.menu === root, root.items.filter({ $0.identifier == Self.identifier }).count == 1 {
            rootChanged = false
            return
        }
        // This identifier is reserved to Mulg. Preserve every game and system menu.
        for duplicate in root.items where duplicate.identifier == Self.identifier { root.removeItem(duplicate) }
        if let oldRoot = item.menu { oldRoot.removeItem(item) }
        let window = root.items.firstIndex { $0.submenu?.items.contains(where: {
            $0.action == #selector(NSWindow.performMiniaturize(_:))
        }) == true }
        root.insertItem(item, at: window ?? root.numberOfItems)
        rootChanged = false
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        perform?(id)
    }

    static func keyEquivalent(_ key: String) -> String {
        switch key {
        case "UIKeyInputUpArrow": "\u{f700}"
        case "UIKeyInputDownArrow": "\u{f701}"
        case "UIKeyInputLeftArrow": "\u{f702}"
        case "UIKeyInputRightArrow": "\u{f703}"
        case "UIKeyInputEscape": "\u{1b}"
        default: key.count == 1 && key.allSatisfy(\.isLetter) ? key.lowercased() : key
        }
    }
}
#endif
