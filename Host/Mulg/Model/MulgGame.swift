//
//  MulgGame.swift
//  Mulg
//

import Cocoa
import Foundation
import Security
import IOKit.pwr_mgt
import MulgLibrary
import MulgContracts

class MulgGame: BaseApp {
    // MARK: - Static
    public static let bundleIDCacheURL = GameRuntime.mulgContainer.appendingPathComponent("CACHE")

    public static var bundleIDCache: [String] {
        get throws {
            (try String(contentsOf: bundleIDCacheURL))
                .split(whereSeparator: \.isNewline)
                .map { String($0) }
        }
    }

    // MARK: - Instance State
    var displaySleepAssertionID: IOPMAssertionID?
    public var isStarting = false
    var sessionDisableKeychain: Bool = false

    // MARK: - Init
    override init(appUrl: URL) {
        super.init(appUrl: appUrl)

        keymapping.reloadKeymapCache()

        // Retiring a legacy registration belongs to a stopped game's next launch,
        // not to a library refresh while its existing process is using that record.
        if !GameWatcher.isRunning(info.bundleIdentifier) {
            removeAlias()
            createAlias()
        }

        loadDiscordIPC()
    }

    /// Signing an unpacked game must not repoint the installed game's Finder alias.
    init(stagedAppUrl: URL) {
        super.init(appUrl: stagedAppUrl)
    }

    // MARK: - Computed
    var searchText: String {
        info.displayName.lowercased()
            .appending(" ")
            .appending(info.bundleName)
            .lowercased()
    }

    var name: String {
        info.displayName.isEmpty ? info.bundleName : info.displayName
    }

    // MARK: - Paths / Singletons
    static let aliasDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications")
        .appendingPathComponent("Mulg")

    lazy var aliasURL = MulgGame.aliasDirectory.appendingPathComponent(name).appendingPathExtension("app")
    lazy var mulgChainURL = MulgVault.mulgChainPath.appendingPathComponent(info.bundleIdentifier)

    lazy var settings = AppSettings(info)
    lazy var keymapping = Keymapping(info)
    lazy var container = AppContainer(bundleId: info.bundleIdentifier)

    // MARK: - Launch
    /// Returns false when the game could not be opened. True also covers a launch the user
    /// turned into an update, or one already under way.
    @discardableResult
    @MainActor func launch(preferGamesCategory: Bool = false) async -> Bool {
        if !prohibitedToPlay, !maliciousProhibited,
           let running = NSRunningApplication.runningApplications(withBundleIdentifier: info.bundleIdentifier)
            .first(where: { !$0.isTerminated }) {
            running.activate(options: [.activateAllWindows])
            monitorSession(running)
            GameWatcher.launchAccepted(info.bundleIdentifier, processIdentifier: running.processIdentifier)
            return true
        }
        guard GameWatcher.beginLaunch(info.bundleIdentifier) else { return true }
        defer { GameWatcher.endLaunch(info.bundleIdentifier) }
        guard !isStarting else { return true }
        isStarting = true
        defer { isStarting = false }
        // A background move to the current runtime (GameRuntime.migrateStoppedGames) holds the game.
        await GameRuntime.finishMigration(info.bundleIdentifier)
        var vaultNeedsLock = false
        var launchLease: GameSessionLease?
        defer { launchLease = nil; if vaultNeedsLock { lockMulgVault() } }
        do {
            try MulgVaultPassword.shared.recoverRotation()

            if prohibitedToPlay {
                try await clearAllCache()
                throw MulgError.appProhibited
            } else if maliciousProhibited {
                let cleanupLease = try GameCleanup.acquireLease(info.bundleIdentifier)
                defer { withExtendedLifetime(cleanupLease) {} }
                try await clearAllCache(sessionLease: cleanupLease)
                try deleteApp()
                throw MulgError.appMaliciousProhibited
            }

            if await VersionCheck.shared.checkNewVersion(myApp: self) { return true }
            launchLease = try GameSessionLease(bundleIdentifier: info.bundleIdentifier)
            try BundleTransaction.recover(info.bundleIdentifier)
            try SettingsStore().withExclusiveAccess(bundleIdentifier: info.bundleIdentifier) {
                try SaveBackup.recover(info.bundleIdentifier)
            }

            settings.sync()
            let dataRoot = try await GameDataStorage.prepareForLaunch(for: url,
                bundleIdentifier: info.bundleIdentifier, sessionLease: launchLease)
            if info[string: "MulgGameDataRoot"] != dataRoot.path {
                try editMetadata(sessionLease: launchLease) { $0["MulgGameDataRoot"] = dataRoot.path }
            }
            if preferGamesCategory, info.applicationCategoryType != .games {
                try setApplicationCategoryType(.games, sessionLease: launchLease)
            }
            // Read by the Home page (MulgGUI HomeGame.lastPlayed).
            UserDefaults.standard.set(Date(), forKey: "library.lastPlayed.\(info.bundleIdentifier)")
            // Home reads the date only when the library republishes; without this, Jump Back In
            // kept the old order until something else changed.
            Task { @MainActor in AppsVM.shared.objectWillChange.send() }

            // Games installed before Games became the default have no category, so macOS Game
            // Mode never engaged for them. Once per game, and only while the default is Games; a
            // category the user picks later (None included) is never overwritten. Info.plist is
            // sealed in the signature, so the game is re-signed as the category picker does.
            let gameModeKey = "library.gameModeCategorySet.\(info.bundleIdentifier)"
            if !UserDefaults.standard.bool(forKey: gameModeKey) {
                if info.applicationCategoryType == .none, InstallPreferences.shared.defaultAppType == .games {
                    try setApplicationCategoryType(.games, sessionLease: launchLease)
                }
                UserDefaults.standard.set(true, forKey: gameModeKey)
            }

            // Install PlugIns/localizations before signing so the bundle is fully
            // assembled before its signature is sealed over its contents.
            // If the app has no runtime, do not install one. Otherwise move it to MulgRuntime's
            // current version (from the retired MulgKit too) and refresh the bridge.
            if hasRuntime() {
                // The runtime the game loads may still be being copied into place.
                try await GameRuntime.waitForSystemInstall()
                try await GameRuntime.refreshInApp(executable, sessionLease: launchLease)
            }

            // The vault opens before the sandbox is built: the sandbox decides whether this launch may move an
            // older Keychain-held login key, and a database still locked then counted as "waiting for unlock".
            // Every vault-locked game (Genshin, Star Rail, …) then started behind the wall with a key it could
            // not read: no saved logins, and every login failed to save (builds 930–931). On a failure below,
            // the defer above locks the vault again.
            try await unlockMulgVault(sessionLease: launchLease)
            vaultNeedsLock = true

            try Entitlements.repairSigning(exec: executable)

            if try !Entitlements.areEntitlementsValid(app: self) {
                try sign(sessionLease: launchLease)
            }

            if try !isInfoPlistSigned() {
                try Shell.signApp(executable)
            }

            if try !GameRuntime.isInstalled() {
                Log.shared.error("MulgRuntime is not installed! Please move Mulg.app into Applications!")
                return false
            } else if try !Macho.isMachoValidArch(executable) {
                Log.shared.error("The app threw an error during conversion.")
                return false
            } else {
                // Prepare the same real bundle for normal and debugger launches, after
                // all signing/replacement work and before handing the lease to a runtime.
                let appURL = url
                let bundleIdentifier = info.bundleIdentifier
                removeAlias()
                let application = try await Task.detached(priority: .userInitiated) {
                    try GameApplicationRegistration.register(appURL,
                        bundleIdentifier: bundleIdentifier, validatingCode: true)
                }.value
                createAlias(for: application)
                let store = SettingsStore()
                // Capture desktop pixels once before the game process starts, for both normal
                // and debugger launches. Activating an already-running game returns above.
                try DesktopLaunchResolution.prepare(for: info.bundleIdentifier, store: store)
                settings.decode()
                let reservation = GameRuntime.supportsModularSettings(atURL: executable) ? try launchLease?.reserveLaunch() : nil
                let launchSettings = store.load(bundleIdentifier: info.bundleIdentifier).settings
                var environment = Self.launchEnvironment(settings: launchSettings,
                    minimalRecovery: LaunchEnvironment.needsMinimalRecovery(marker: store.paths.safeModeMarker(for: info.bundleIdentifier), settings: launchSettings))
                environment[GameSessionLease.launchTokenEnvironmentKey] = reservation?.token
                defer { withExtendedLifetime(reservation) {} }
                if reservation != nil { launchLease = nil } // Token-bearing runtime takes the session lease.

                if settings.openWithLLDB {
                    let monitor = monitorDebugLaunch(reservation: reservation, preparingLease: launchLease)
                    do {
                        try await Shell.lldb(executable, withTerminalWindow: settings.openLLDBWithTerminal,
                                             environment: environment)
                    } catch { monitor.cancel(); throw error }
                } else {
                    try await runAppExec(application: application, environment: environment, reservation: reservation)
                }
                launchLease = nil
                vaultNeedsLock = false
            }
            return true
        } catch {
            Log.shared.error(error)
            return false
        }
    }
}

// MARK: - Environment Management
extension MulgGame {
    static let introspection: String = "/usr/lib/system/introspection"
    static let iosFrameworks: String = "/System/iOSSupport/System/Library/Frameworks"

    static func launchEnvironment(settings: GameSettings, minimalRecovery: Bool = false) -> [String: String] {
        LaunchEnvironment.make(settings, inherited: ProcessInfo.processInfo.environment, minimalRecovery: minimalRecovery)
    }

    @MainActor func runAppExec(application: URL, environment: [String: String], reservation: GameLaunchReservation?) async throws {
        let config = NSWorkspace.OpenConfiguration()

        config.environment = environment

        // UIKit's executable URL and Launch Services identity refer to this one bundle.
        let startedAt = Date()
        let runningApp = try await NSWorkspace.shared.openApplication(at: application, configuration: config)
        monitorSession(runningApp)
        if let reservation {
            let networkVolume = (try? executable.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == false
            let deadline = ContinuousClock.now + .seconds(networkVolume ? 120 : 30)
            while !reservation.isClaimed {
                guard !runningApp.isTerminated else {
                    if let failure = RuntimeStartupFailure.current(paths: SettingsStore().paths,
                        bundleIdentifier: info.bundleIdentifier, processIdentifier: runningApp.processIdentifier,
                        startedAt: startedAt) {
                        throw failure.message
                    }
                    throw "The game exited before its runtime could accept the launch reservation. Check the game's crash report."
                }
                guard ContinuousClock.now < deadline else {
                    runningApp.forceTerminate()
                    // Keep the reservation locked until the timed-out process has actually exited.
                    Task { @MainActor in
                        defer { withExtendedLifetime(reservation) {} }
                        while !runningApp.isTerminated {
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                    }
                    throw "Game startup timed out before its runtime accepted the launch reservation."
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        if !runningApp.isTerminated {
            GameWatcher.launchAccepted(info.bundleIdentifier, processIdentifier: runningApp.processIdentifier)
        }
    }

    @MainActor private func monitorDebugLaunch(reservation: GameLaunchReservation?, preparingLease: GameSessionLease?) -> Task<Void, Never> {
        Task { @MainActor in
            defer { withExtendedLifetime((reservation, preparingLease)) {} }
            // LLDB attaches and loads every image's symbols before the game runs: 21 s for Genshin
            // on an external drive. Giving up earlier released the reservation and locked the vault
            // while the game was still starting.
            for _ in 0..<720 {
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: info.bundleIdentifier)
                    .first(where: { !$0.isTerminated }), reservation?.isClaimed != false {
                    monitorSession(app)
                    GameWatcher.launchAccepted(info.bundleIdentifier, processIdentifier: app.processIdentifier)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            Log.shared.error("Debugger did not launch \(info.bundleIdentifier) within 3 minutes")
            lockMulgVault()
        }
    }

    @MainActor private func monitorSession(_ runningApp: NSRunningApplication) {
        let pid = runningApp.processIdentifier
        guard GameWatcher.beginMonitoring(pid) else { return }
        // Run a thread loop in the background to handle background tasks
        Task(priority: .background) {
            defer {
                self.enableTimeOut()
                GameWatcher.endMonitoring(pid)
            }
            while !runningApp.isTerminated {
                if runningApp.isActive && self.settings.settings.disableTimeout {
                    self.disableTimeOut()
                } else {
                    self.enableTimeOut()
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            try? await Task.sleep(for: .seconds(1))
            // Things that are run after the app is closed
            if !GameWatcher.isRunning(self.info.bundleIdentifier) { self.lockMulgVault() }
        }
    }
}

// MARK: - Management
extension MulgGame {
    func disableTimeOut() {
        if displaySleepAssertionID != nil { return }

        let reason = "Mulg: \(info.bundleIdentifier) is disabling sleep" as CFString
        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        )
        if result == kIOReturnSuccess {
            displaySleepAssertionID = assertionID
        }
    }

    func enableTimeOut() {
        if let assertionID = displaySleepAssertionID {
            IOPMAssertionRelease(assertionID)
            displaySleepAssertionID = nil
        }
    }
}

// MARK: - MulgVault
extension MulgGame {
    func unlockMulgVault(sessionLease: GameSessionLease? = nil) async throws {
        if MulgVault.shared.isMulgVaultEnabled() {
            let keychain = MulgVault.shared.listKeychains()
                .first(where: { $0.appBundleID == self.info.bundleIdentifier })

            if let keychain = keychain, keychain.chainEncryptionStatus {
                try await MulgVault.shared.unlockChain(keychain, sessionLease: sessionLease)

                if MulgVault.shared.mulgVaultPlainTextKey == nil {
                    // Pop an alert telling the user that keychain was not unlocked
                    // and keychain is disabled for the session
                    Task { @MainActor in
                        let alert = NSAlert()
                        alert.messageText = NSLocalizedString("mulgvault.alert.title", comment: "")
                        alert.informativeText = NSLocalizedString("mulgvault.alert.content", comment: "")
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: NSLocalizedString("button.OK", comment: ""))
                        alert.runModal()
                    }
                    settings.settings.mulgChain = false
                    sessionDisableKeychain = true
                }
            }
        }
    }

    func lockMulgVault() {
        guard !GameWatcher.isRunning(info.bundleIdentifier),
              let lease = try? GameSessionLease(bundleIdentifier: info.bundleIdentifier) else { return }
        defer { withExtendedLifetime(lease) {} }
        if MulgVault.shared.isMulgVaultEnabled() {
            if sessionDisableKeychain {
                settings.settings.mulgChain = true
                sessionDisableKeychain = false
                return
            }

            let keychain = MulgVault.shared.listKeychains()
                .first(where: { $0.appBundleID == self.info.bundleIdentifier })

            if let keychain = keychain, !keychain.chainEncryptionStatus {
                try? MulgVault.shared.lockChain(keychain, sessionLease: lease)
            }
        }
    }
}

// MARK: - Tools
extension MulgGame {
    func hasRuntime() -> Bool {
        do {
            return try GameRuntime.installedInExec(atURL: url.appendingEscapedPathComponent(info.executableName))
        } catch {
            Log.shared.error(error)
            return true
        }
    }

    func editMetadata(sessionLease: GameSessionLease? = nil, update: (inout [String: Any]) throws -> Void) throws {
        let lease = try sessionLease ?? GameSessionLease(bundleIdentifier: info.bundleIdentifier)
        defer { withExtendedLifetime(lease) {} }
        guard !GameWatcher.isRunning(info.bundleIdentifier) else { throw GameSessionLease.Failure.busy }
        let name = info.executableName
        try GameInstaller.editMetadata(app: url, bundleIdentifier: info.bundleIdentifier, update: update,
            sign: { working in try Shell.signApp(working.appendingPathComponent(name), recordInjection: false) })
        try info.reload()
        GameRuntime.recordInjection(executable)
    }

    func setApplicationCategoryType(_ category: LSApplicationCategoryType, sessionLease: GameSessionLease? = nil) throws {
        try editMetadata(sessionLease: sessionLease) { metadata in
            metadata["LSApplicationCategoryType"] = category == .none ? nil : category.rawValue
        }
    }

    func changeDyldLibraryPath(set: Bool? = nil, path: String) async throws -> Bool {
        if let set {
            try editMetadata { metadata in
                var environment = metadata["LSEnvironment"] as? [String: String] ?? [:]
                var paths = (environment["DYLD_LIBRARY_PATH"] ?? "").split(separator: ":").map(String.init)
                paths.removeAll { $0 == path }
                if set { paths.append(path) }
                environment["DYLD_LIBRARY_PATH"] = paths.isEmpty ? nil : paths.joined(separator: ":") + ":"
                metadata["LSEnvironment"] = environment.isEmpty ? nil : environment
            }
        }
        return (info.lsEnvironment["DYLD_LIBRARY_PATH"] ?? "").split(separator: ":").contains(Substring(path))
    }
}

// MARK: - FS / Codesign
extension MulgGame {
    func hasAlias() -> Bool {
        FileManager.default.fileExists(atPath: aliasURL.path)
    }

    /// Whether the signature seals Info.plist (codesign's "Info.plist entries"), read in-process.
    func isInfoPlistSigned() throws -> Bool {
        Entitlements.signingInformation(exec: executable)?[kSecCodeInfoPList as String] != nil
    }

    func showInFinder() {
        URL(fileURLWithPath: url.path).showInFinderAndSelectLastComponent()
    }

    func openAppCache() {
        container.containerUrl.showInFinderAndSelectLastComponent()
    }

    func clearAllCache(sessionLease: GameSessionLease? = nil) async throws {
        try GameCleanup.trashCaches(for: info.bundleIdentifier, sessionLease: sessionLease)
    }

    func clearMulgChain(sessionLease: GameSessionLease? = nil) throws {
        try GameCleanup.removeCredentials(for: info.bundleIdentifier, sessionLease: sessionLease)
    }

    func deleteApp() throws {
        // Games installed in another folder (an external drive) have a link in the library. Resolve it
        // first: removing the link and then deleting through it left the real game on the drive.
        let link = AppsVM.appDirectory.appendingEscapedPathComponent(info.bundleIdentifier).appendingPathExtension("app")
        let installed = url.resolvingSymlinksInPath()
        defer { AppsVM.shared.fetchApps() }
        if (try? installed.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
           GameRemovalScan.isOnDisconnectedVolume(installed) == false,
           FileManager.default.fileExists(atPath: installed.path) {
            try GameCleanup.removeStubbornly(installed)
        }
        // The library entry stays when the bundle could not be deleted, so the player can retry.
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil {
            try FileManager.default.removeItem(at: link)
        }
    }

    func sign(sessionLease: GameSessionLease? = nil) throws {
        let lease = try sessionLease ?? GameSessionLease(bundleIdentifier: info.bundleIdentifier)
        defer { withExtendedLifetime(lease) {} }
        guard !GameWatcher.isRunning(info.bundleIdentifier) else { throw GameSessionLease.Failure.busy }
        let tmpEnts = FileManager.default.temporaryDirectory
            .appendingEscapedPathComponent(ProcessInfo().globallyUniqueString)
            .appendingPathExtension("plist")
        defer { try? FileManager.default.removeItem(at: tmpEnts) }
        let conf = try Entitlements.composeEntitlements(self)
        try conf.store(tmpEnts)
        try Shell.signAppWith(executable, entitlements: tmpEnts)
    }
}

// MARK: - Policies
extension MulgGame {
    var prohibitedToPlay: Bool {
        MulgGame.PROHIBITED_APPS.contains(info.bundleIdentifier)
    }

    var maliciousProhibited: Bool {
        MulgGame.MALICIOUS_APPS.contains(info.bundleIdentifier)
    }

    static let PROHIBITED_APPS = [
        "com.activision.callofduty.shooter",
        "com.ea.ios.apexlegendsmobilefps",
        "com.tencent.tmgp.cod",
        "com.tencent.ig",
        "com.pubg.newstate",
        "com.pubg.imobile",
        "com.tencent.tmgp.pubgmhd",
        "com.dts.freefireth",
        "com.dts.freefiremax",
        "vn.vng.codmvn",
        "com.ngame.allstar.eu",
        "com.axlebolt.standoff2",
        "com.tencent.lolm"
    ]

    static let MALICIOUS_APPS = [
        "com.zhiliaoapp.musically"
    ]
}
