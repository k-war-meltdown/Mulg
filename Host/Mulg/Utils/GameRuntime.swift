//
//  GameRuntime.swift
//  Mulg
//

import Foundation
import MulgGUI
import MulgLibrary
import MulgContracts

/// Puts MulgRuntime (Apps/Runtime) and its AppKit bridge into games and keeps them current.
///
/// MulgRuntime is the only game runtime. The older MulgKit runtime is retired (PLAN.md §16.11):
/// this app neither ships nor installs it. A game still linked to it is recognised
/// (`retiredMulgKitPath`) and moved to MulgRuntime at Mulg's start or its next launch, and the
/// retired framework is removed from ~/Library/Frameworks once no game links it.
// swiftlint:disable:next type_body_length
class GameRuntime {
    private static let legacyRuntimeFramework = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Frameworks/MulgRuntime.framework")
    private static var runtimeFramework: URL {
        get throws { try runtimeVersion.get() }
    }
    private static let runtimeVersion: Result<URL, Error> = Result {
        try RuntimeInstaller.versionedFramework(bundled: bundledRuntimeFramework)
    }
    private static var runtimePath: URL {
        get throws { try runtimeFramework.appendingPathComponent("MulgRuntime") }
    }
    private static let bundledRuntimeFramework = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Frameworks/MulgRuntime.framework")
    private static let bundledBridge = Bundle.main.bundleURL
        .appendingPathComponent("Contents/PlugIns/MulgBridge.bundle")

    /// The app carries MulgRuntime and its bridge (a broken or partial copy of Mulg does not).
    static var runtimeAvailable: Bool {
        FileManager.default.fileExists(atPath: bundledRuntimeFramework.path)
            && FileManager.default.fileExists(atPath: bundledBridge.path)
    }

    /// The retired MulgKit runtime, kept only to recognise and move games still linked to it.
    private static let retiredMulgKitFramework = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Frameworks/GameRuntime.framework")
    private static let retiredMulgKitPath = retiredMulgKitFramework.appendingPathComponent("MulgKit")
    /// What MulgKit put into a game: its AppKit plug-in and its strings in every localisation.
    private static let retiredPlugin = "PlugIns/MulgAppKit.bundle"
    private static let retiredStrings = "GameRuntime.strings"

    public static var mulgContainer: URL {
        let mulgPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Containers")
            .appendingPathComponent("io.mulg.Mulg")
        if !FileManager.default.fileExists(atPath: mulgPath.path) {
            do {
                try FileManager.default.createDirectory(at: mulgPath,
                                                        withIntermediateDirectories: true,
                                                        attributes: [:])
            } catch {
                Log.shared.error(error)
            }
        }

        return mulgPath
    }

    /// Puts the bundled MulgRuntime in ~/Library/Frameworks. It is staged and swapped in
    /// (RuntimeInstaller.replace), so a failed copy keeps the working framework; launches wait
    /// for this first (waitForSystemInstall).
    static func installOnSystem() {
        _ = systemInstall
    }

    static func waitForSystemInstall() async throws {
        try await systemInstall.value
    }

    private static let systemInstall = Task.detached(priority: .utility) {
        guard runtimeAvailable else { throw MulgError.runtimeNotLinked }
        Log.shared.log("Copying MulgRuntime to Frameworks")
        try RuntimeInstaller.validatePair(framework: bundledRuntimeFramework, bridge: bundledBridge)
        _ = try RuntimeInstaller.installVersion(bundled: bundledRuntimeFramework, bridge: bundledBridge)
        // Preserve an existing shared runtime for games not migrated by this host yet.
        if !FileManager.default.fileExists(atPath: legacyRuntimeFramework.path) {
            try RuntimeInstaller.replace(legacyRuntimeFramework, with: bundledRuntimeFramework)
        }
        try RuntimeInstaller.validateInstalled(runtimeFramework, bundled: bundledRuntimeFramework, bridge: bundledBridge)
        // Every build adds a version; keep this one and the ones installed games still link.
        guard let linked = linkedRuntimes() else { return }
        var keep = Set(linked.compactMap(RuntimeInstaller.versionName(inLoadPath:)))
        if let current = RuntimeInstaller.versionName(inLoadPath: try runtimePath.path) { keep.insert(current) }
        let removed = RuntimeInstaller.pruneVersions(keeping: keep)
        if !removed.isEmpty { Log.shared.log("Removed \(removed.count) unused runtime versions") }
        // The retired runtime goes once every game has moved off it.
        let files = FileManager.default
        if !linked.contains(retiredMulgKitPath.path), files.fileExists(atPath: retiredMulgKitFramework.path) {
            do {
                try files.removeItem(at: retiredMulgKitFramework)
                Log.shared.log("Removed the retired MulgKit runtime")
            } catch {
                Log.shared.error(error)
            }
        }
    }

    /// The runtime libraries the library's games link, or nil when any game cannot be read (its
    /// drive is not mounted, say): then nothing may be removed.
    private static func linkedRuntimes() -> Set<String>? {
        let files = FileManager.default
        guard let entries = try? files.contentsOfDirectory(at: AppsVM.appDirectory, includingPropertiesForKeys: nil)
        else { return nil }
        var runtimes: Set<String> = []
        for entry in entries where entry.pathExtension == "app" {
            let app = entry.resolvingSymlinksInPath()
            let plist = app.appendingPathComponent("Info.plist")
            guard files.fileExists(atPath: plist.path),
                  let linked = try? injectedRuntimes(atURL: app.appendingPathComponent(AppInfo(contentsOf: plist).executableName))
            else { return nil }
            runtimes.formUnion(linked)
            // SDKs also carry constructor dependencies. Never prune a version they still load.
            do {
                for binary in GameInstaller.findBinaries(in: app) {
                    runtimes.formUnion(try injectedRuntimes(atURL: binary))
                }
            } catch { return nil }
        }
        return runtimes
    }

    /// `sign: false` when the caller signs the whole app afterwards anyway (a new install signs it
    /// with its entitlements once Info.plist is final), so the game is not hashed twice (§16.3 E7).
    static func installInIPA(_ exec: URL, sign: Bool = true) async throws {
        try await waitForSystemInstall()
        guard sign else { try link(exec); return }
        let app = exec.deletingLastPathComponent()
        let info = AppInfo(contentsOf: app.appendingPathComponent("Info.plist"))
        let lease = try GameSessionLease(bundleIdentifier: info.bundleIdentifier)
        defer { withExtendedLifetime(lease) {} }
        guard !GameWatcher.isRunning(info.bundleIdentifier) else { throw GameSessionLease.Failure.busy }
        try GameInstaller.editInstalled(app: app, bundleIdentifier: info.bundleIdentifier,
            prepare: { working in
                try link(working.appendingPathComponent(exec.lastPathComponent), signDependencies: true)
                try DependencyValidation.validate(app: working, binaries: GameInstaller.findBinaries(in: working))
            }, sign: { working in
                try Shell.signApp(working.appendingPathComponent(exec.lastPathComponent), recordInjection: false)
            })
        recordInjection(exec)
    }

    /// Links the runtime and its bridge/plugins in a staged bundle, before its signing pass.
    private static func link(_ exec: URL, signDependencies: Bool = false) throws {
        try RuntimeInstaller.validateInstalled(runtimeFramework, bundled: bundledRuntimeFramework, bridge: bundledBridge)
        try MachOBinary.editLibraries(at: exec, adding: [runtimePath.path])
        try prepareInstalledGame(exec, signDependencies: signDependencies)
    }

    /// The shared installer calls this after conversion and before its single signing pass.
    static func prepareInstalledGame(_ exec: URL, signDependencies: Bool = false) throws {
        let payload = exec.deletingLastPathComponent()
        let modified = try GameRuntimeDependencies.synchronize(in: payload, mainExecutable: exec, runtimePath: runtimePath.path)
        if signDependencies {
            try GameRuntimeDependencies.resignChangedLibraries(modified, in: payload, mainExecutable: exec)
        }
        var binary = try Data(contentsOf: exec)
        if try MachOBinary.restoreGameAllocatorExports(&binary) > 0 {
            let attributes = try FileManager.default.attributesOfItem(atPath: exec.path)
            try binary.write(to: exec, options: .atomic)
            if let mode = attributes[.posixPermissions] {
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: exec.path)
            }
        }
        try installBridgeInIPA(payload)
        try removeRetiredFiles(from: payload)
        let info = AppInfo(contentsOf: payload.appendingPathComponent("Info.plist"))
        try GameInstaller.synchronizePointerInput(in: payload,
            settings: SettingsStore().load(bundleIdentifier: info.bundleIdentifier).settings)
        try syncUserDylibs(bundleIdentifier: info.bundleIdentifier, into: exec)
    }

    /// Takes MulgKit's plug-in and strings out of a game moving to MulgRuntime. The plug-in would
    /// otherwise stay signed into the bundle, unused.
    private static func removeRetiredFiles(from payload: URL) throws {
        let files = FileManager.default
        var retired = [payload.appendingPathComponent(retiredPlugin)]
        let entries = (try? files.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)) ?? []
        for folder in entries where folder.pathExtension == "lproj" {
            retired.append(folder.appendingPathComponent(retiredStrings))
        }
        for file in retired where files.fileExists(atPath: file.path) { try files.removeItem(at: file) }
    }

    /// Before each launch: moves the game to MulgRuntime's current version and gives it the
    /// current bridge.
    ///
    /// Link and sign a staged clone, then replace the installed bundle. A failed refresh
    /// retains the previous runtime and bridge and stops this launch so it can be retried.
    /// Games opened from the Dock, Launchpad or Spotlight skip Play's step that moves them to this
    /// app's runtime and bridge, so after a Mulg update they kept the old ones (fixes included).
    /// When Mulg starts, every installed game that is not running moves now, one at a time, in
    /// the background. A current game needs only dependency metadata and bridge checks;
    /// Play waits for its game's move.
    @MainActor private static var migrations: [String: Task<Void, Never>] = [:]

    @MainActor static func migrateStoppedGames(_ games: [MulgGame]) {
        var previous: Task<Void, Never>?
        for game in games where game.hasRuntime() && !GameWatcher.isRunning(game.info.bundleIdentifier) {
            let identifier = game.info.bundleIdentifier, executable = game.executable
            let after = previous
            let move = Task.detached(priority: .utility) {
                await after?.value
                do {
                    try await refreshInApp(executable)
                    try Entitlements.repairSigning(exec: executable)
                } catch {
                    Log.shared.log("Runtime update of \(identifier) waits for its next launch: \(error)")
                }
            }
            migrations[identifier] = move
            previous = move
        }
    }

    @MainActor static func finishMigration(_ identifier: String) async {
        await migrations[identifier]?.value
    }

    static func refreshInApp(_ exec: URL, sessionLease: GameSessionLease? = nil) async throws {
        let info = AppInfo(contentsOf: exec.deletingLastPathComponent().appendingPathComponent("Info.plist"))
        let lease = try sessionLease ?? GameSessionLease(bundleIdentifier: info.bundleIdentifier)
        defer { withExtendedLifetime(lease) {} }
        guard !GameWatcher.isRunning(info.bundleIdentifier) else { throw GameSessionLease.Failure.busy }
        try BundleTransaction.recover(info.bundleIdentifier)
        try await waitForSystemInstall()
        try RuntimeInstaller.validateInstalled(runtimeFramework, bundled: bundledRuntimeFramework, bridge: bundledBridge)
        let wanted = try runtimePath.path
        let linked = try injectedRuntimes(atURL: exec)
        let payload = exec.deletingLastPathComponent()
        let gameSettings = SettingsStore().load(bundleIdentifier: info.bundleIdentifier).settings
        if linked == [wanted], bridgeIsCurrent(in: payload),
           try GameInstaller.pointerInputIsCurrent(in: payload, settings: gameSettings),
           try GameRuntimeDependencies.isCurrent(in: payload, mainExecutable: exec, runtimePath: wanted) {
            // A crash after bundle commit can leave the trust stamp at the previous version.
            // Repair it only from an intact signed bundle, never from edited plugin bytes.
            let settings = gameSettings.mulg.engine
            if settings.trustedPluginHashes != GameInstaller.pluginHashes(in: payload)
                || settings.injectedRuntimeProtocol != MulgVersion.runtimeProtocol {
                try BundleTransaction.verifySignature(payload)
                try GameActions().recordInjection(of: info.bundleIdentifier, app: payload)
            }
            return
        }
        // A runtime that is not on this Mac would leave the game unable to start.
        guard try isInstalled() else { return }
        Log.shared.log("Moving \(exec.deletingLastPathComponent().lastPathComponent) to MulgRuntime")

        let files = FileManager.default
        let scratch = try BundleTransaction.workingDirectory(for: payload)
        defer { try? files.removeItem(at: scratch) }
        let working = scratch.appendingPathComponent(payload.lastPathComponent)
        try BundleTransaction.copy(payload, to: working)  // APFS can clone unchanged local game assets
        let stagedExec = working.appendingPathComponent(exec.lastPathComponent)

        do {
            if linked != [wanted] {
                let replacement = linked.first.map { [$0: wanted] } ?? [:]
                try MachOBinary.editLibraries(at: stagedExec, adding: [wanted], removing: linked.sorted(), replacing: replacement)
            }
            try prepareInstalledGame(stagedExec, signDependencies: true)
            try DependencyValidation.validate(app: working, binaries: GameInstaller.findBinaries(in: working))
            try Shell.signApp(stagedExec, recordInjection: false)
            guard try injectedRuntimes(atURL: stagedExec) == [wanted] else { throw MulgError.runtimeNotLinked }
            try BundleTransaction.replace(working, at: payload, bundleIdentifier: info.bundleIdentifier)
            recordInjection(exec)
        } catch {
            Log.shared.error(error)
            try BundleTransaction.verifySignature(payload)
            Log.shared.log("Kept the runtime \(exec.deletingLastPathComponent().lastPathComponent) had")
            // Do not launch an old bridge against a newly installed runtime after a failed refresh.
            throw error
        }
    }

    private static func bridgeIsCurrent(in payload: URL) -> Bool {
        let target = payload.appendingPathComponent("PlugIns/MulgBridge.bundle")
        func version(_ bundle: URL) -> String? {
            NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String
        }
        guard let installed = version(target), installed == version(bundledBridge),
              (try? RuntimeManifest.read(at: target.appendingPathComponent("Contents/Resources/" + RuntimeManifest.fileName)))
                == RuntimeManifest() else { return false }
        do {
            try RuntimeInstaller.validatePair(framework: bundledRuntimeFramework, bridge: target)
            try BundleTransaction.verifySignature(target)
            return true
        } catch { return false }
    }

    /// Copies the AppKit bridge MulgRuntime loads from the game's `PlugIns` folder, unless the
    /// game already has this build of it (the build stamps CFBundleVersion; signing the copy
    /// does not change its Info.plist).
    static func installBridgeInIPA(_ payload: URL) throws {
        try RuntimeInstaller.validatePair(framework: bundledRuntimeFramework, bridge: bundledBridge)
        let target = payload.appendingPathComponent("PlugIns/MulgBridge.bundle")
        if bridgeIsCurrent(in: payload) { return }
        let files = FileManager.default
        try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".MulgBridge-\(UUID().uuidString).bundle")
        defer { try? files.removeItem(at: staging) }
        try files.copyItem(at: bundledBridge, to: staging)
        try Shell.signMacho(staging)
        guard try RuntimeManifest.read(at: staging.appendingPathComponent("Contents/Resources/" + RuntimeManifest.fileName))
                == RuntimeManifest() else { throw MulgError.runtimeNotLinked }
        if files.fileExists(atPath: target.path) {
            _ = try files.replaceItemAt(target, withItemAt: staging)
        } else {
            try files.moveItem(at: staging, to: target)
        }
    }

    /// MulgRuntime asks for a re-inject when a game carries no runtime version, and loads only
    /// user plugins whose hash the app recorded (PLAN.md §1.5 rule 6). Call after every
    /// signing pass, because signing rewrites the plugins.
    static func recordInjection(_ exec: URL) {
        do {
            guard try injectedRuntimes(atURL: exec).contains(runtimePath.path) else { return }
            let payload = exec.deletingLastPathComponent()
            let info = AppInfo(contentsOf: payload.appendingPathComponent("Info").appendingPathExtension("plist"))
            try GameActions().recordInjection(of: info.bundleIdentifier, app: payload)
        } catch {
            Log.shared.error(error)
        }
    }

    // Exported IPAs carry MulgRuntime and its bridge inside, and run away from this Mac.
    static func injectInIPA(_ exec: URL, payload: URL) throws {
        try RuntimeInstaller.validatePair(framework: bundledRuntimeFramework, bridge: bundledBridge)
        let frameworks = payload.appendingPathComponent("Frameworks")
        let target = frameworks.appendingPathComponent("MulgRuntime.framework")
        try GameRuntimeDependencies.synchronize(in: payload, mainExecutable: exec,
            runtimePath: "@executable_path/Frameworks/MulgRuntime.framework/MulgRuntime")
        let info = AppInfo(contentsOf: payload.appendingPathComponent("Info.plist"))
        try GameInstaller.synchronizePointerInput(in: payload,
            settings: SettingsStore().load(bundleIdentifier: info.bundleIdentifier).settings)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.copyItem(at: bundledRuntimeFramework, to: target)
        try installBridgeInIPA(payload)
    }

    static func removeFromApp(_ exec: URL) async {
        let info = AppInfo(contentsOf: exec.deletingLastPathComponent().appendingPathComponent("Info.plist"))
        guard !GameWatcher.isRunning(info.bundleIdentifier),
              let lease = try? GameSessionLease(bundleIdentifier: info.bundleIdentifier) else { return }
        defer { withExtendedLifetime(lease) {} }
        do {
            try GameInstaller.editInstalled(app: exec.deletingLastPathComponent(), bundleIdentifier: info.bundleIdentifier,
                prepare: { working in
                    let stagedExec = working.appendingPathComponent(exec.lastPathComponent)
                    let modified = try GameRuntimeDependencies.synchronize(in: working, mainExecutable: stagedExec, runtimePath: nil)
                    try GameInstaller.restorePointerInput(in: working)
                    try GameRuntimeDependencies.resignChangedLibraries(modified, in: working, mainExecutable: stagedExec)
                    let bridge = working.appendingPathComponent("PlugIns/MulgBridge.bundle")
                    if FileManager.default.fileExists(atPath: bridge.path) { try FileManager.default.removeItem(at: bridge) }
                    try removeRetiredFiles(from: working)
                }, sign: { working in
                    try Shell.signApp(working.appendingPathComponent(exec.lastPathComponent), recordInjection: false)
                }
            )
        } catch {
            Log.shared.error(error)
        }
    }

    static func installedInExec(atURL url: URL) throws -> Bool {
        try !injectedRuntimes(atURL: url).isEmpty
    }

    static func supportsModularSettings(atURL url: URL) -> Bool {
        ((try? injectedRuntimes(atURL: url).contains(where: RuntimeInstaller.isRuntimeLibrary)) ?? false)
    }

    /// The runtimes the executable links: MulgRuntime, or the retired MulgKit for a game that has
    /// not moved yet. Called on every launch and by the game list, so the file is mapped: only
    /// the pages with load commands are read.
    static func injectedRuntimes(atURL url: URL) throws -> Set<String> {
        var binary = try Data(contentsOf: url, options: .alwaysMapped)
        try Macho.stripBinary(&binary)
        return Set(try MachOBinary.loadedLibraries(in: binary).filter {
            $0 == retiredMulgKitPath.path || RuntimeInstaller.isRuntimeLibrary($0)
        })
    }

    static func isInstalled() throws -> Bool {
        try RuntimeInstaller.validateInstalled(runtimeFramework, bundled: bundledRuntimeFramework, bridge: bundledBridge)
        return try FileManager.default.fileExists(atPath: runtimePath.path)
            && Macho.isMachoValidArch(runtimePath)
    }

    // User plugins loading. The store keeps the folder name MulgKit used, so saved plug-ins stay.
    private static func userPluginsStore(bundleIdentifier: String) -> URL {
        mulgContainer
            .appendingPathComponent("MulgKit")
            .appendingPathComponent("UserPlugins")
            .appendingPathComponent(bundleIdentifier)
    }

    static func userDylibs(bundleIdentifier: String) -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: userPluginsStore(bundleIdentifier: bundleIdentifier), includingPropertiesForKeys: nil) else {
            return []
        }
        return files.filter { $0.pathExtension == "dylib" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func addUserDylib(at sourceURL: URL, bundleIdentifier: String, appExecutable: URL) throws {
        try editUserDylibs(bundleIdentifier: bundleIdentifier, appExecutable: appExecutable) { folder in
            let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard sourceURL.pathExtension == "dylib", values.isRegularFile == true, values.isSymbolicLink != true else { throw MulgError.invalidUserDylib }
            let oldCard = folder.appendingPathComponent("Frameworks/UserPlugins/" + sourceURL.lastPathComponent)
                .deletingPathExtension().appendingPathExtension("module.json")
            if FileManager.default.fileExists(atPath: oldCard.path) { try FileManager.default.removeItem(at: oldCard) }
            try GameInstaller.installPlugins([sourceURL], into: folder)
            let candidate = folder.appendingPathComponent("Frameworks/UserPlugins/" + sourceURL.lastPathComponent)
            let original = try Data(contentsOf: candidate)
            guard try !MachOBinary.isEncrypted(MachOBinary.arm64Slice(of: original)) else { throw MulgError.appEncrypted }
            try MachOBinary.convertForMac(original, keepSDK: true).write(to: candidate, options: .atomic)
            _ = try? Shell.run(print: false, "/usr/bin/xattr", "-d", "com.apple.quarantine", candidate.path)
        }
    }

    static func removeUserDylib(named name: String, bundleIdentifier: String, appExecutable: URL) throws {
        guard URL(fileURLWithPath: name).lastPathComponent == name, name.hasSuffix(".dylib") else { throw MulgError.invalidUserDylib }
        try editUserDylibs(bundleIdentifier: bundleIdentifier, appExecutable: appExecutable) { folder in
            let candidate = folder.appendingPathComponent("Frameworks/UserPlugins/" + name)
            for file in [candidate, candidate.deletingPathExtension().appendingPathExtension("module.json")]
                where FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }

    private static func editUserDylibs(bundleIdentifier: String, appExecutable: URL, edit: (URL) throws -> Void) throws {
        let lease = try GameSessionLease(bundleIdentifier: bundleIdentifier)
        defer { withExtendedLifetime(lease) {} }
        guard !GameWatcher.isRunning(bundleIdentifier) else { throw GameSessionLease.Failure.busy }
        try BundleTransaction.recover(bundleIdentifier)
        let files = FileManager.default
        let scratch = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: scratch) }
        let plugins = scratch.appendingPathComponent("Frameworks/UserPlugins")
        try files.createDirectory(at: plugins, withIntermediateDirectories: true)
        for source in userDylibs(bundleIdentifier: bundleIdentifier) {
            try GameInstaller.installPlugins([source], into: scratch)
        }
        try edit(scratch)
        try GameInstaller.editInstalled(app: appExecutable.deletingLastPathComponent(), bundleIdentifier: bundleIdentifier,
            companions: [userPluginsStore(bundleIdentifier: bundleIdentifier): plugins], prepare: { working in
                let target = working.appendingPathComponent("Frameworks/UserPlugins")
                if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
                try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try files.copyItem(at: plugins, to: target)
                for file in try files.contentsOfDirectory(at: target, includingPropertiesForKeys: nil) where file.pathExtension == "dylib" {
                    try file.fixExecutable()
                    try Shell.signMacho(file)
                }
                try DependencyValidation.validate(app: working, binaries: GameInstaller.findBinaries(in: working))
            }, sign: { working in
                try Shell.signApp(working.appendingPathComponent(appExecutable.lastPathComponent), recordInjection: false)
            })
        recordInjection(appExecutable)
    }

    // Resync
    static func syncUserDylibs(bundleIdentifier: String, into appExecutable: URL) throws {
        let targetDirectory = appExecutable.deletingLastPathComponent()
            .appendingPathComponent("Frameworks")
            .appendingPathComponent("UserPlugins")

        if FileManager.default.fileExists(atPath: targetDirectory.path) {
            try FileManager.default.removeItem(at: targetDirectory)
        }

        let dylibs = userDylibs(bundleIdentifier: bundleIdentifier)
        guard !dylibs.isEmpty else { return }

        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        for source in dylibs {
            let target = targetDirectory.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: target)
            try target.fixExecutable()
            try Shell.signMacho(target)
            let card = source.deletingPathExtension().appendingPathExtension("module.json")
            if FileManager.default.fileExists(atPath: card.path) {
                try FileManager.default.copyItem(at: card, to: targetDirectory.appendingPathComponent(card.lastPathComponent))
            }
        }
    }
}
