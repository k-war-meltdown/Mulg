//
//  MulgApp.swift
//  Mulg
//

import MulgGUI
import MulgLibrary
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first {
            URLHandler.shared.processURL(url: url)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        GameMenuBarController.shared.start()
        do { try BundleTransaction.recoverPending() }
        catch { Log.shared.error(error) }
        do { try DesktopGameDefaults.migrate() }
        catch { Log.shared.error(error) }
        Task { @MainActor in
            await AppsVM.shared.fetchApps().value
            // Debugging only runs while switched on in a game's settings this session: each start of Mulg
            // switches it off again for every installed game (2026-10-11, user request).
            for app in AppsVM.shared.apps {
                do { try GameActions().switchOffDebugging(for: app.info.bundleIdentifier) }
                catch { Log.shared.log("Debugging not switched off for \(app.info.bundleIdentifier): \(error)", isError: true) }
            }
            GameRuntime.migrateStoppedGames(AppsVM.shared.apps)
        }
        MulgAppearance.saved.apply()
        Installer.newGameDefaults = { bundleIdentifier in
            do {
                try DefaultProfile.applyToNewGame(bundleIdentifier)
            } catch {
                // The game keeps its defaults; not worth an alert.
                Log.shared.log("\(error)", isError: true)
            }
            BundledKeymaps.seed(bundleIdentifier)
            return DefaultProfile.saved == .fps120
        }
        UpdateScheme.checkForUpdate()

        UserDefaults.standard.register(
            defaults: ["NSApplicationCrashOnExceptions": true]
        )

        URLCache.iconCache.removeAllCachedResponses()
        do { try MulgVaultPassword.shared.recoverRotation() } catch { Log.shared.error(error) }
        // Code that run once on first launch
        let launchedBefore = UserDefaults.standard.bool(forKey: "launchedBefore")
        if !launchedBefore {
            // Initialize MulgVault with an automatically generated key
            let mulgVaultPassword = MulgVaultPassword.shared.generateVerySecurePassword()
            do {
                try MulgVaultPassword.shared.setMulgVaultPassword(mulgVaultPassword)
                MulgVaultPreferences.shared.mulgVaultEnabled = .selfGeneratedPassword
                UserDefaults.standard.set(true, forKey: "launchedBefore")
            } catch { Log.shared.error(error) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !GameMenuBarController.shared.keepsRunningAfterWindowClose
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if GameMenuBarController.shared.keepsRunningAfterWindowClose {
            GameMenuBarController.shared.showLibrary()
            return false
        }
        return true
    }
}

@main
struct MulgApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject var updaterViewModel = UpdaterViewModel()
    var storeVM = StoreVM.shared

    @State var isSigningSetupShown = false

    var body: some Scene {
        WindowGroup(id: GameMenuBarController.libraryWindowID) {
            MainView(isSigningSetupShown: $isSigningSetupShown)
                .mulgMenuBarLibraryWindow()
                .mulgAppearance()
                .environmentObject(InstallVM.shared)
                .environmentObject(DownloadVM.shared)
                .environmentObject(AppsVM.shared)
                .environmentObject(storeVM)
                .environmentObject(AppIntegrity())
                .onAppear {
                    NSWindow.allowsAutomaticWindowTabbing = false
                    SoundDeviceService.shared.prepareSoundDevice()
                    NotifyService.shared.allowNotify()
                }
        }
        .handlesExternalEvents(matching: ["{same path of URL?}"]) // create new window if doesn't exist
        .commands {
            SidebarCommands()
            MulgMenuView(isSigningSetupShown: $isSigningSetupShown)
            MulgHelpMenuView(updaterViewModel: updaterViewModel)
            MulgViewMenuView()
        }

        Settings {
            MulgSettingsView(updaterViewModel: updaterViewModel)
                .mulgAppearance()
                .mulgWindowBackground()
                .environmentObject(storeVM)
        }
    }
}
