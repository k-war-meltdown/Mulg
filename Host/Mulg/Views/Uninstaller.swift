//
//  Uninstaller.swift
//  Mulg
//
//  Created by TheMoonThatRises on 9/26/22.
//

import SwiftUI
import MulgContracts
import MulgLibrary

struct CheckBoxHelper {
    var view: NSView
    var button: NSButton
    var buttonvar: String
}

class Uninstaller {
    @MainActor static func removeCompletelyPopup(_ app: MulgGame) async {
        await removeCompletelyPopup(url: app.url, id: app.info.bundleIdentifier, name: app.name)
    }

    /// Scans every connected drive first (read-only, cancellable), lists what was found, then removes it.
    @MainActor private static func removeCompletelyPopup(url: URL, id: String, name: String) async {
        do {
            let lease = try GameCleanup.acquireLease(id)
            defer { withExtendedLifetime(lease) {} }
            var askedForScanAccess: Set<String> = []
            while true {
                let scanAlert = NSAlert()
                scanAlert.messageText = "Finding files for \(name)…"
                scanAlert.informativeText = "Checking game locations on every connected drive, plus matching IPA and backup metadata. Only files verified for this game can be selected. Nothing is changed during this check."
                let spinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
                spinner.style = .spinning; spinner.startAnimation(nil)
                scanAlert.accessoryView = spinner
                scanAlert.addButton(withTitle: "Cancel")
                let chosen = UserDefaults.standard.string(forKey: "gui.installFolder").flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
                let scan = Task.detached(priority: .utility) {
                    try GameRemovalScan.discover(app: url, bundleIdentifier: id, installFolders: chosen.map { [$0] } ?? [])
                }
                let existingParent = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first(where: { $0.isVisible })
                let parent = existingParent ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 160),
                    styleMask: [.titled], backing: .buffered, defer: false)
                if existingParent == nil { parent.title = "Mulg"; parent.center(); parent.makeKeyAndOrderFront(nil) }
                defer { if existingParent == nil { parent.close() } }
                scanAlert.beginSheetModal(for: parent) { response in
                    if response == .alertFirstButtonReturn { scan.cancel() }
                }
                let result = await scan.result
                parent.endSheet(scanAlert.window, returnCode: .abort)
                scanAlert.window.orderOut(nil)
                let inventory: GameRemovalScan.Inventory
                do { inventory = try result.get() } catch is CancellationError { return }
                guard !scan.isCancelled else { return }

                let alert = NSAlert()
                alert.messageText = "Remove \(name) and all data?"
                let sharesData = !inventory.nativeApps.isEmpty
                alert.informativeText = "Checked \(inventory.checkedFolders.count) game/source folders on the connected drives and found \(inventory.items.count) verified locations (listed below). Permanently remove this game's installs, Support data, matching source IPAs and save backups, plus its Mulg settings, keymaps and saved logins. Unrelated files and name-only matches are kept. This cannot be undone."
                    + (sharesData ? "\n\nA native Mac app with the same bundle ID is kept, along with its shared container, caches and preferences." : "")
                    + (inventory.unavailableRoots.isEmpty ? "" : "\n\n\(inventory.unavailableRoots.count) recorded data locations are on disconnected drives. They are saved for Retry Incomplete Removals.")
                    + (inventory.issues.isEmpty ? "" : "\n\nSome folders could not be checked. Allow folder access to scan them; shared Library data is kept while the scan is incomplete.")
                let details = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 200))
                details.isEditable = false; details.isSelectable = true
                details.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                details.string = (inventory.items.map { $0.kind.rawValue + ": " + $0.url.path }
                    + inventory.nativeApps.map { "Kept (Mac app): " + $0.path }
                    + inventory.sharedGroups.map { "Kept (shared App Group; exclusive ownership unverified): " + $0 }
                    + inventory.unavailableRoots.map { "Disconnected: " + $0.path } + inventory.issues).joined(separator: "\n")
                let scroll = NSScrollView(frame: details.frame)
                scroll.hasVerticalScroller = true; scroll.documentView = details
                alert.accessoryView = scroll
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Remove Game and All Data").hasDestructiveAction = true
                alert.addButton(withTitle: "Cancel")
                if !inventory.deniedFolders.isEmpty { alert.addButton(withTitle: "Allow Folder Access and Scan Again…") }
                let response = alert.runModal()
                if response == .alertThirdButtonReturn {
                    let fresh = inventory.deniedFolders.filter { !askedForScanAccess.contains($0.path) }
                    guard !fresh.isEmpty else { offerFullDiskAccess(inventory.deniedFolders); return }
                    for folder in fresh {
                        askedForScanAccess.insert(folder.path)
                        guard requestRemovalAccess(folder, scanning: true) else { return }
                    }
                    continue
                }
                guard response == .alertFirstButtonReturn else { return }
                do {
                    try await withRemovalAccess {
                        _ = try await Task.detached(priority: .utility) {
                            try GameCleanup.removeCompletely(app: url, bundleIdentifier: id, sessionLease: lease, inventory: inventory,
                                trash: { sharesData ? try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
                                                    : try GameCleanup.removeStubbornly($0) })
                        }.value
                    }
                } catch {
                    AppsVM.shared.fetchApps()
                    throw error
                }
                if let cached = try? MulgGame.bundleIDCache {
                    try? (cached.filter { $0 != id }.joined(separator: "\n") + "\n")
                        .write(to: MulgGame.bundleIDCacheURL, atomically: true, encoding: .utf8)
                }
                AppsVM.shared.fetchApps()
                return
            }
        } catch { await showCleanupFailure(error) }
    }

    /// Finishes removals left by a disconnected drive or a refused deletion.
    @MainActor static func retryIncompleteRemovalsPopup() async {
        do {
            let pending = try GameCleanup.pendingRemovals()
            guard !pending.isEmpty else {
                let alert = NSAlert(); alert.messageText = "No incomplete removals"
                alert.informativeText = "There are no saved game removals to retry."
                alert.runModal(); return
            }
            for item in pending {
                await removeCompletelyPopup(url: item.app, id: item.bundleIdentifier, name: item.bundleIdentifier)
            }
        } catch { await showCleanupFailure(error) }
    }
    @MainActor
    private static func createButtonView(_ yaxis: CGFloat, _ text: String, _ varname: String) -> CheckBoxHelper {
        let button = NSButton(checkboxWithTitle: text, target: self, action: nil)

        if UninstallPreferences.shared.value(forKey: varname) as? Bool ?? true {
            button.animator().setNextState()
        }

        let view = NSView(frame: NSRect(x: 0, y: yaxis,
                                        width: button.fittingSize.width,
                                        height: button.fittingSize.height))

        view.addSubview(button)

        return CheckBoxHelper(view: view, button: button, buttonvar: varname)
    }

    @MainActor
    static func uninstallPopup(_ app: MulgGame) async {
        if UninstallPreferences.shared.showUninstallPopup {
            let boxmakers: [(String, String)] = [
                ("removeMulgChain", NSLocalizedString("preferences.toggle.removeMulgChain", comment: "")),
                ("removeAppEntitlements", NSLocalizedString("preferences.toggle.removeEntitlements", comment: "")),
                ("removeAppSettings", NSLocalizedString("preferences.toggle.removeSetting", comment: "")),
                ("removeAppKeymap", NSLocalizedString("preferences.toggle.removeKeymap", comment: "")),
                ("clearAppData", NSLocalizedString("preferences.toggle.clearAppData", comment: ""))
            ]

            var checkboxes: [CheckBoxHelper] = []

            var viewY = 0.0

            for (buttonvar, buttontitle) in boxmakers {
                checkboxes.append(createButtonView(viewY, buttontitle, buttonvar))
                viewY += checkboxes[checkboxes.count - 1].view.frame.height
            }

            let viewWidth = checkboxes.max(by: { $0.view.frame.width < $1.view.frame.width })?.view.frame.width

            let settingsView = NSStackView(frame: NSRect(x: 0, y: 0, width: viewWidth ?? 0, height: viewY))

            for checkboxhelper in checkboxes {
                settingsView.addSubview(checkboxhelper.view)
            }

            let alert = NSAlert()
            alert.messageText = NSLocalizedString("mulggame.delete", comment: "")
            alert.informativeText = String(format: NSLocalizedString("mulggame.deleteMessage",
                                                                     comment: ""),
                                           arguments: [app.name])

            alert.alertStyle = .warning
            alert.accessoryView = settingsView

            let delete = alert.addButton(withTitle: NSLocalizedString("mulggame.deleteConfirm", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("button.Cancel", comment: ""))

            alert.showsSuppressionButton = true
            alert.suppressionButton?.toolTip = NSLocalizedString("alert.supression", comment: "")

            delete.hasDestructiveAction = true

            NSApplication.shared.requestUserAttention(.criticalRequest)
            guard let window = NSApplication.shared.windows.first,
                  await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            for checkboxhelper in checkboxes {
                UninstallPreferences.shared.setValue(checkboxhelper.button.state == .on,
                                                     forKey: checkboxhelper.buttonvar)
            }

            if alert.suppressionButton?.state == .on {
                UninstallPreferences.shared.showUninstallPopup = false
            }

            await uninstall(app)
        } else {
            await uninstall(app)
        }
    }

    /// Keymaps and settings go to the Trash, as the game's data already does, so an uninstall
    /// can be undone with Put Back. MulgChain (account tokens) is still deleted for good.
    private static func trash(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Each step runs even when an earlier one fails, so a refused data folder never keeps the game
    /// itself installed. Refusals by macOS ask the player for permission first (`withRemovalAccess`).
    @MainActor static func uninstall(_ app: MulgGame) async {
        do {
            let lease = try GameCleanup.acquireLease(app.info.bundleIdentifier)
            defer { withExtendedLifetime(lease) {} }
            var uninstallNum = 0, failures: [Error] = []
            func step(_ enabled: Bool, _ body: () async throws -> Void) async {
                guard enabled else { return }
                do { try await withRemovalAccess(body); uninstallNum += 1 } catch { failures.append(error) }
            }
            let preferences = UninstallPreferences.shared
            await step(preferences.clearAppData) { try await app.clearAllCache(sessionLease: lease) }
            await step(preferences.removeAppKeymap) { try trash(app.keymapping.baseKeymapURL) }
            await step(preferences.removeAppSettings) { try trash(app.settings.settingsUrl) }
            await step(preferences.removeAppEntitlements) { FileManager.default.delete(at: app.legacyEntitlements) }
            await step(preferences.removeMulgChain) { try app.clearMulgChain(sessionLease: lease) }

            app.removeAlias()
            try await withRemovalAccess { try app.deleteApp() }

            if uninstallNum >= 5 {
                do {
                    let apps = (try MulgGame.bundleIDCache).filter({ $0 != app.info.bundleIdentifier })
                        .joined(separator: "\n") + "\n"
                    try apps.write(to: MulgGame.bundleIDCacheURL, atomically: false, encoding: .utf8)
                } catch {
                    Log.shared.error(error)
                }
            }
            if let failure = failures.first { throw failure }
        } catch {
            await showCleanupFailure(error)
        }
    }

    /// macOS protects other apps' containers (the game's sandbox folder, shown in Finder under the
    /// game's name) and drives or folders Mulg has not been allowed into. Choosing the item in an Open
    /// panel is the player's permission; the operation is then retried. When macOS still refuses,
    /// Full Disk Access is offered.
    @MainActor static func withRemovalAccess(_ operation: () async throws -> Void) async throws {
        var asked: Set<String> = []
        while true {
            do { try await operation(); return }
            catch {
                let denied = GameCleanup.deniedItems(in: error)
                let fresh = denied.filter { !asked.contains($0.standardizedFileURL.path) }
                guard !fresh.isEmpty else {
                    if !denied.isEmpty { offerFullDiskAccess(denied) }
                    throw error
                }
                for url in fresh {
                    asked.insert(url.standardizedFileURL.path)
                    guard requestRemovalAccess(url) else { throw error }
                }
            }
        }
    }

    @MainActor private static func requestRemovalAccess(_ url: URL, scanning: Bool = false) -> Bool {
        let isFolder = scanning || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = !scanning
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = isFolder ? url : url.deletingLastPathComponent()
        panel.prompt = scanning ? "Allow Scan" : "Allow Removal"
        panel.message = scanning
            ? "Allow Mulg to check this folder for the selected game's files:\n" + url.path + "\nScanning does not delete or change any files."
            : "macOS needs your permission before Mulg can remove “\(FileManager.default.displayName(atPath: url.path))”:\n"
                + url.path + "\n" + (isFolder ? "Click Allow Removal." : "Select it, then click Allow Removal.")
        NSApplication.shared.activate()
        guard panel.runModal() == .OK, let chosen = panel.url else { return false }
        let wanted = url.resolvingSymlinksInPath().standardizedFileURL.path
        if chosen.resolvingSymlinksInPath().standardizedFileURL.path == wanted { return true }
        let alert = NSAlert()
        alert.messageText = "A different item was chosen"
        alert.informativeText = "To allow the removal, choose exactly:\n" + wanted
        alert.runModal()
        return false
    }

    @MainActor private static func offerFullDiskAccess(_ urls: [URL]) {
        let alert = NSAlert()
        alert.messageText = "macOS still blocks this removal"
        alert.informativeText = "Turn on Mulg in System Settings → Privacy & Security → Full Disk Access, then uninstall again.\n\n"
            + urls.prefix(6).map(\.path).joined(separator: "\n")
        alert.addButton(withTitle: "Open Full Disk Access")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(settings)
        }
    }

    @MainActor
    static func clearCachePopup(_ app: MulgGame) async {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("alert.app.delete", comment: "")
        alert.alertStyle = .warning

        let proceed = alert.addButton(withTitle: NSLocalizedString("button.Proceed", comment: ""))
        proceed.hasDestructiveAction = true
        alert.addButton(withTitle: NSLocalizedString("button.Cancel", comment: ""))

        NSApplication.shared.requestUserAttention(.criticalRequest)
        guard let window = NSApplication.shared.windows.first,
              await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }

        await clearCache(of: app)
    }

    @MainActor static func clearCache(of app: MulgGame) async {
        do { try await withRemovalAccess { try await app.clearAllCache() } }
        catch { await showCleanupFailure(error) }
    }

    @MainActor
    static func showCleanupFailure(_ error: Error) async {
        Log.shared.error(error)
        let alert = NSAlert()
        alert.messageText = "Cleanup failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        if let window = NSApplication.shared.windows.first {
            _ = await alert.beginSheetModal(for: window)
        } else { alert.runModal() }
    }

    static func pruneFiles() {
        do {
            // A game on a drive that is not connected is missing from the app list (its library link
            // points nowhere) but is still installed: its container, saves and logins must stay. Every
            // library entry counts, link or folder; an unreadable library prunes nothing.
            let entries = try FileManager.default.contentsOfDirectory(atPath: AppsVM.appDirectory.path)
            let installed = Set(AppsVM.shared.apps.map { $0.info.bundleIdentifier })
                .union(entries.filter { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) })
            let cached = try MulgGame.bundleIDCache
            var pruned: Set<String> = []
            for identifier in Set(cached).subtracting(installed) {
                do {
                    let lease = try GameCleanup.acquireLease(identifier)
                    defer { withExtendedLifetime(lease) {} }
                    for item in try GameCleanup.pruneItems(for: identifier) { try trash(item) }
                    pruned.insert(identifier)
                } catch GameSessionLease.Failure.busy {
                    continue
                } catch { Log.shared.error(error) }
            }
            try (cached.filter { !pruned.contains($0) }.joined(separator: "\n") + "\n")
                .write(to: MulgGame.bundleIDCacheURL, atomically: true, encoding: .utf8)
        } catch {
            Log.shared.error(error)
        }
    }
}
