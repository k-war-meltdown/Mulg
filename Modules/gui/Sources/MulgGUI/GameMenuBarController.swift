#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import MulgContracts
import MulgLibrary
import os
import SwiftUI

/// Hide the launcher during play, then return to the regular library after the last game exits.
@MainActor
public final class GameMenuBarController: NSObject, NSMenuDelegate {
    public static let shared = GameMenuBarController()
    public static let preferenceKey = "mulg.minimizeToMenuBarOnLaunch"
    public static let libraryWindowID = "mulg.library"
    private var statusItem: NSStatusItem?
    private var observers: [NSObjectProtocol] = []
    private let libraryWindows = NSHashTable<NSWindow>.weakObjects()
    private var games: [pid_t: NSRunningApplication] = [:]
    private var openLibrary: (() -> Void)?
    private enum PresentationState: Equatable { case library, menuBar, restoring, terminating }
    private var presentationState = PresentationState.library
    private var openingLibraryWindow = false
    private var started = false
    /// Running and closing games from the shared tracker (GameWatcher.runStateUpdates).
    private var runStates: [String: GameWatcher.RunState] = [:]
    private var stateTask: Task<Void, Never>?
    private let logger = Logger(subsystem: MulgLog.subsystem, category: "menubar")

    public var keepsRunningAfterWindowClose: Bool {
        guard presentationState != .terminating else { return false }
        // Keep the host alive while SwiftUI recreates a previously closed library window.
        return presentationState == .restoring || (statusItem != nil && enabled && !games.isEmpty)
    }
    private var enabled: Bool { UserDefaults.standard.object(forKey: Self.preferenceKey) as? Bool ?? true }

    public func start() {
        guard !started else { return }
        started = true
        // The same tracker as Home and the library: launches, exits and a check every second, so a
        // missed or mismatched quit notification can never keep the library hidden.
        stateTask = Task { @MainActor [weak self] in
            for await states in GameWatcher.runStateUpdates() { self?.runStatesChanged(states) }
        }
        observers.append(NotificationCenter.default.addObserver(forName: GameWatcher.launchAcceptedNotification,
                                                                object: nil, queue: .main) { [weak self] note in
            let identifier = note.userInfo?["bundleIdentifier"] as? String
            let pid = (note.userInfo?["processIdentifier"] as? NSNumber)?.int32Value
            MainActor.assumeIsolated {
                if let identifier, let pid { self?.acceptedLaunch(identifier, pid: pid) }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferenceChanged() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                                           object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            let identifier = app?.bundleIdentifier
            let launchDate = app?.launchDate
            MainActor.assumeIsolated {
                if let pid { self?.gameTerminated(pid: pid, identifier: identifier, launchDate: launchDate) }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.presentationState = .terminating }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                                object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let window, self.libraryWindows.contains(window) else { return }
                self.libraryWindows.remove(window)
                // SwiftUI finishes its close before the launcher changes activation policy.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.keepsRunningAfterWindowClose,
                          !self.libraryWindows.allObjects.contains(where: { $0.isVisible }) else { return }
                    self.hideLibrary()
                }
            }
        })
    }

    fileprivate func register(_ window: NSWindow) {
        libraryWindows.add(window)
        openingLibraryWindow = false
        guard presentationState == .restoring || presentationState == .menuBar else { return }
        // Wait for SwiftUI to finish attaching a recreated library window before focusing it.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.libraryWindows.contains(window) else { return }
            if self.presentationState == .restoring {
                self.bringForward(window)
                self.presentationState = .library
                NSApp.activate()
            } else if self.presentationState == .menuBar, self.enabled, !self.games.isEmpty {
                // A new accepted launch can overtake asynchronous window recreation.
                window.orderOut(nil)
            }
        }
    }

    fileprivate func setLibraryOpener(_ action: @escaping () -> Void) {
        openLibrary = action
        if presentationState == .restoring, libraryWindows.allObjects.isEmpty { requestLibraryWindow() }
    }

    /// SwiftUI sometimes drops a window request made while the app was an accessory: ask again once
    /// if no library window registered within two seconds, so the launcher never stays hidden.
    private func retryLibraryWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.presentationState == .restoring, self.libraryWindows.allObjects.isEmpty else { return }
            self.logger.notice("Library window did not open; asking again")
            self.openingLibraryWindow = false
            self.requestLibraryWindow()
            NSApp.activate()
        }
    }

    private func requestLibraryWindow() {
        guard !openingLibraryWindow, let openLibrary else { return }
        openingLibraryWindow = true
        openLibrary()
    }

    private func acceptedLaunch(_ identifier: String, pid: pid_t) {
        guard presentationState != .terminating,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.bundleIdentifier == identifier, pid != ProcessInfo.processInfo.processIdentifier else { return }
        games[pid] = app
        guard enabled else { return }
        createStatusItem()
        refreshGames()
        guard statusItem != nil, games[pid] != nil else { return }
        hideLibrary()
    }

    private func createStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = (Bundle.module.image(forResource: "MulgMark")?.copy() as? NSImage)
            ?? NSImage(systemSymbolName: "chevron.up.2", accessibilityDescription: "Mulg")
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        item.button?.image = image
        item.button?.setAccessibilityLabel("Mulg")
        item.button?.toolTip = "Mulg"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func hideLibrary() {
        guard presentationState != .terminating, enabled, statusItem != nil, !games.isEmpty else { return }
        logger.notice("Library hidden while \(self.games.count, privacy: .public) game(s) run")
        presentationState = .menuBar
        // Accessory apps have a menu-bar presence but no Dock tile or Command-Tab entry.
        NSApp.setActivationPolicy(.accessory)
        NSApp.hide(nil)
    }

    public func showLibrary() {
        guard presentationState != .terminating else { return }
        presentationState = .restoring
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        let windows = libraryWindows.allObjects
        if windows.isEmpty { requestLibraryWindow() }
        logger.notice("Library shown (\(windows.count, privacy: .public) window(s))")
        if windows.isEmpty { retryLibraryWindow() }
        else {
            openingLibraryWindow = false
            for window in windows { bringForward(window) }
            presentationState = .library
        }
        NSApp.activate()
    }

    private func bringForward(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    private func removeStatusItem() {
        guard let item = statusItem else { return }
        item.menu?.cancelTracking()
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    private func preferenceChanged() {
        guard !enabled, statusItem != nil else { return }
        if presentationState == .menuBar || NSApp.isHidden { showLibrary() }
        removeStatusItem()
    }

    private func gameTerminated(pid: pid_t, identifier: String?, launchDate: Date?) {
        // Whatever this notification names, drop every tracked game that has exited: one that was
        // missed must not keep the library hidden.
        defer { refreshGames() }
        guard let tracked = games[pid] else { return }
        // A process that no longer exists is gone, whatever the notification's details say.
        if !Self.isAlive(pid) { games[pid] = nil; return }
        if let identifier, tracked.bundleIdentifier != identifier { return }
        // A delayed notification must not remove a later process that reused the same PID.
        if let launchDate, let trackedDate = tracked.launchDate, launchDate != trackedDate { return }
        games[pid] = nil
    }

    private func refreshGames() {
        let before = games.count
        games = games.filter { !$0.value.isTerminated && Self.isAlive($0.key) }
        if games.count != before { logger.notice("Game exited; \(self.games.count, privacy: .public) still running") }
        let count = games.count
        if count == 0, statusItem != nil {
            showLibrary()
            removeStatusItem()
            return
        }
        statusItem?.button?.toolTip = count == 0 ? "Mulg · Open library" : "Mulg · \(count) game\(count == 1 ? "" : "s") running"
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        refreshGames()
        menu.removeAllItems()
        guard statusItem != nil, presentationState != .terminating else { return }
        add("Open Mulg", action: #selector(openFromMenu(_:)), to: menu)
        if !NSApp.isHidden { add("Hide Mulg", action: #selector(hideFromMenu(_:)), to: menu) }
        let running = games.values.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        if !running.isEmpty {
            menu.addItem(.separator())
            for app in running {
                let name = app.localizedName ?? app.bundleIdentifier ?? "game"
                if app.bundleIdentifier.map({ runStates[$0] == .closing }) == true {
                    // Saving before it exits; it has no window to return to.
                    let item = add("\(name) is closing…", action: #selector(returnToGame(_:)), to: menu)
                    item.isEnabled = false
                    continue
                }
                let item = add("Return to \(name)", action: #selector(returnToGame(_:)), to: menu)
                item.representedObject = NSNumber(value: app.processIdentifier)
            }
        }
        menu.addItem(.separator())
        add("Quit Mulg", action: #selector(quitFromMenu(_:)), to: menu)
    }

    @discardableResult
    private func add(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }
    @objc private func openFromMenu(_ sender: NSMenuItem) { showLibrary() }
    @objc private func hideFromMenu(_ sender: NSMenuItem) { hideLibrary() }
    @objc private func quitFromMenu(_ sender: NSMenuItem) {
        presentationState = .terminating
        NSApp.terminate(nil)
    }
    @objc private func returnToGame(_ sender: NSMenuItem) {
        guard let pid = (sender.representedObject as? NSNumber)?.int32Value,
              let app = games[pid], !app.isTerminated else { return }
        hideLibrary()
        app.activate(options: [.activateAllWindows])
    }
}

extension GameMenuBarController {
    /// Every second and on each launch or exit: forget games whose process is gone (then the
    /// library comes back) and remember which are closing, for the menu.
    fileprivate func runStatesChanged(_ states: [String: GameWatcher.RunState]) {
        runStates = states
        refreshGames()
    }

    /// The kernel still has the process (a terminated NSRunningApplication can lag behind).
    fileprivate static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

private struct LibraryWindowRegistration: NSViewRepresentable {
    final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { GameMenuBarController.shared.register(window) }
        }
    }
    func makeNSView(context: Context) -> WindowView { WindowView(frame: .zero) }
    func updateNSView(_ view: WindowView, context: Context) {}
}

private struct MenuBarLibraryWindow: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.background(LibraryWindowRegistration().frame(width: 0, height: 0))
            .onAppear {
                let open = openWindow
                GameMenuBarController.shared.setLibraryOpener { open(id: GameMenuBarController.libraryWindowID) }
            }
    }
}

public extension View {
    func mulgMenuBarLibraryWindow() -> some View { modifier(MenuBarLibraryWindow()) }
}
#endif
