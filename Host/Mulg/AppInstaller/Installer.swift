//
//  Installer.swift
//  Mulg
//
//  Created by Александр Дорофеев on 24.11.2021.
//

import Foundation
import MulgContracts
import MulgLibrary

class Installer {
    /// Set by the app at launch for its "profile for new games" setting (gui). Called with the
    /// bundle ID before Info.plist is written; returns true when the profile needs the Games
    /// category (Game Mode). library does not import gui, so the setting reaches it this way.
    nonisolated(unsafe) static var newGameDefaults: (@Sendable (String) -> Bool)?


    @MainActor static func installMulgKitPopup() -> Bool {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("alert.install.injectMulgKitQuestion", comment: "")
        alert.informativeText = NSLocalizedString("alert.install.mulgKitInformative", comment: "")

        alert.alertStyle = .informational

        alert.showsSuppressionButton = true
        alert.suppressionButton?.toolTip = NSLocalizedString("alert.supression", comment: "String")

        let yes = alert.addButton(withTitle: NSLocalizedString("button.Yes", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("button.No", comment: ""))

        // Set default button to install mulgkit
        yes.keyEquivalent = "\r"

        let response = alert.runModal()

        if alert.suppressionButton?.state == .on {
            InstallPreferences.shared.showInstallPopup = false
            InstallPreferences.shared.alwaysInstallMulgKit = response == .alertFirstButtonReturn
        }

        return response == .alertFirstButtonReturn
    }

    /// A damaged IPA: cancel (the default), or install with the damaged files incomplete.
    @MainActor static func installDamagedPopup(_ damage: IPA.DamagedArchive) -> Bool {
        let alert = NSAlert()
        alert.messageText = "This IPA is damaged"
        alert.informativeText = "\(damage.fileList) failed its checksum while unpacking: part of its data is missing "
            + "in the IPA file itself. Every other file is fine.\n\n"
            + "You can install anyway, with the damaged file incomplete. The game may crash or report missing data "
            + "when it reads that file. A good copy of the IPA avoids this."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Install Anyway")
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// After an install the player chose despite damaged files: what is incomplete and what to do.
    @MainActor static func installedIncompletePopup(game: String, files: [String], exported: Bool = false) {
        let alert = NSAlert()
        alert.messageText = "\(game) \(exported ? "exported" : "installed"), but not completely"
        let shown = files.prefix(3).joined(separator: ", ") + (files.count > 3 ? " and \(files.count - 3) more" : "")
        alert.informativeText = "These files were damaged in the IPA and are incomplete: \(shown).\n\n"
            + "If the game crashes, freezes or reports missing or corrupt data, that is the cause, not Mulg. "
            + "Install a good copy of the IPA over this one to fix it; your saved data stays."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    static private func returnErrorString(error: Error) -> String {
        // A dependency failure already identifies the binary and missing library.
        // Do not turn an IPA-named staging path into a generic corrupt-archive alert.
        if let failure = error as? DependencyValidation.Failure { return failure.localizedDescription }
        return switch error.localizedDescription {
        case let str where str.contains("(disk full?)"): NSLocalizedString("alert.notSpace", comment: "")
        case let str where str.contains(".html"): NSLocalizedString("alert.quota.limit", comment: "")
        case let str where str.contains(".ipa"): NSLocalizedString("alert.corrupted", comment: "")
        default: NSLocalizedString(error.localizedDescription, comment: "")
        }
    }

    // swiftlint:disable:next function_body_length
    /// `folder` is where the app goes; outside Mulg's library the library keeps a link to it.
    @MainActor static func install(ipaUrl: URL, export: Bool, into folder: URL = AppsVM.appDirectory,
                        returnCompletion: @escaping @Sendable (URL?) -> Void) {
        // Installed games always need the runtime to place downloads beside their app.
        let installMulgKit = true
        let applicationType = InstallPreferences.shared.defaultAppType

        InstallVM.shared.next(.begin, 0.0, 0.0)

        // Detached so the unzip, convert and sign steps stay off the main thread.
        Task.detached(priority: .userInitiated) {
            let ipa = IPA(url: ipaUrl)
            defer { ipa.releaseTempDir() }

            do {
                InstallVM.shared.next(.unzip, 0.0, 0.5)
                try ipa.allocateTempDir()

                let app: BaseApp
                // Files the IPA delivered damaged, when the player chose to install anyway.
                var damagedFiles: [String] = []
                do {
                    app = try ipa.unzip()
                } catch let damage as IPA.DamagedArchive where damage.canInstallAnyway {
                    guard await MainActor.run(body: { installDamagedPopup(damage) }) else {
                        InstallVM.shared.next(.failed, 0.95, 1.0)
                        returnCompletion(nil)
                        return
                    }
                    damagedFiles = damage.files
                    Log.shared.log("Installing a damaged IPA anyway; incomplete: \(damage.files.joined(separator: ", "))", isError: true)
                    app = try ipa.unpackedApp()
                }
                Log.shared.log("Installing \(ipaUrl.path): \(app.info.bundleIdentifier) from \(app.url.lastPathComponent) into \(folder.path)")
                if await ipa.checkOfficialMacOS(app: IPA.Application.base(app)) {
                    InstallVM.shared.next(.failed, 0.95, 1.0)
                    returnCompletion(nil)
                    return
                }
                InstallVM.shared.next(.library, 0.5, 0.55)
                try saveEntitlements(app)
                InstallVM.shared.next(.mulgkit, 0.55, 0.85)

                // The 120 FPS default profile needs Game Mode, which the Games category turns on.
                let wantsGameMode = !export && (newGameDefaults?(app.info.bundleIdentifier) ?? false)
                // An update keeps the category the installed copy had, so Game Mode stays on after it.
                let installed = export ? nil : installedCategory(of: app.info.bundleIdentifier)
                app.info.applicationCategoryType = installed
                    ?? (applicationType == .none && wantsGameMode ? .games : applicationType)

                if !export {
                    try removeMobileProvision(app)
                }

                let info = app.info
                info.assert(minimumVersion: 27.0)
                // Lets the game draw above 60 FPS on a 120 Hz display (PLAN §4.2). iOS asks for it on
                // iPhone ProMotion models only; harmless for iPad identities.
                info[object: "CADisableMinimumFrameDurationOnPhone"] = NSNumber(value: true)
                try info.write()
                var finalURL: URL

                if export {
                    let machos = resolveValidMachOs(app)
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for macho in machos {
                            group.addTask {
                                if try Macho.isMachoEncrypted(atURL: macho) { throw MulgError.appEncrypted }
                            }
                        }
                        try await group.waitForAll()
                    }
                    try GameRuntime.injectInIPA(app.executable, payload: app.url)
                    InstallVM.shared.next(.wrapper, 0.85, 0.95)
                    finalURL = try ipa.packIPABack(app: app.url)
                    try ipa.removeQuarantine(finalURL)
                } else {
                    var settings = SettingsStore().load(bundleIdentifier: app.info.bundleIdentifier).settings
                    let entitlementFile = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString).appendingPathExtension("plist")
                    defer { try? FileManager.default.removeItem(at: entitlementFile) }
                    let installedURL = GameInstaller.destination(bundleIdentifier: info.bundleIdentifier, in: folder, library: AppsVM.appDirectory)
                    let dataRoot: URL
                    do {
                        dataRoot = try GameDataStorage.createRoot(for: installedURL, bundleIdentifier: info.bundleIdentifier)
                    } catch where GameDataStorage.isPermissionError(error) {
                        guard await GameDataStorage.requestAccess(for: installedURL, bundleIdentifier: info.bundleIdentifier) else { throw error }
                        dataRoot = try GameDataStorage.createRoot(for: installedURL, bundleIdentifier: info.bundleIdentifier)
                    }
                    info[string: "MulgGameDataRoot"] = dataRoot.path
                    try info.write()
                    try Entitlements.composeEntitlements(MulgGame(stagedAppUrl: app.url), dataRoot: dataRoot).store(entitlementFile)
                    let executable = app.executable
                    try await GameInstaller.install(
                        app: app.url,
                        options: .init(runtimePath: nil, entitlements: entitlementFile, allowProhibited: true,
                                       allowRestrictedEntitlements: SystemConfig.isMulgSignActive),
                        settings: &settings,
                        prepare: { _ in
                            // Conversion replaces the executable, so restore its launch permission afterwards.
                            try executable.setBinaryPosixPermissions(0o755)
                            if installMulgKit { try await GameRuntime.installInIPA(executable, sign: false) }
                        })
                    let capabilityReport = app.url.appendingPathComponent("MulgCapabilities.json")
                    if let report = try? String(contentsOf: capabilityReport, encoding: .utf8) {
                        Log.shared.log("Capabilities requiring original provisioning for \(info.bundleIdentifier): \(report)")
                    }
                    // Signing just sealed every file; check the signed code, not gigabytes of assets again.
                    try BundleTransaction.verifyCode(app.url)
                    InstallVM.shared.next(.wrapper, 0.85, 0.95)
                    try ipa.removeQuarantine(app.url)
                    finalURL = try wrap(app, into: folder)
                    GameRuntime.recordInjection(finalURL.appendingPathComponent(app.info.executableName))
                    _ = MulgGame(appUrl: finalURL)
                }

                InstallVM.shared.next(.finish, 0.95, 1.0)
                returnCompletion(finalURL)
                if !damagedFiles.isEmpty {
                    let name = app.info.displayName.isEmpty ? app.info.bundleName : app.info.displayName
                    let files = damagedFiles
                    await MainActor.run { installedIncompletePopup(game: name, files: files, exported: export) }
                }
            } catch {
                Log.shared.log("IPA installation failed: \(error)", isError: true)
                Log.shared.error(returnErrorString(error: error))
                InstallVM.shared.next(.failed, 0.95, 1.0)
                returnCompletion(nil)
            }
        }
    }

    static func fromIPA(detectingAppNameInFolder folderURL: URL) throws -> BaseApp {
        let contents = try FileManager.default.contentsOfDirectory(atPath: folderURL.path)

        var url: URL?

        for entry in contents {
            guard entry.hasSuffix(".app") else {
                continue
            }

            let entryURL = folderURL.appendingEscapedPathComponent(entry)
            var isDirectory: ObjCBool = false

            guard FileManager.default.fileExists(atPath: entryURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            guard url == nil else {
                throw "The IPA contains multiple application bundles. Choose an IPA containing one game."
            }
            url = entryURL
        }

        guard let url = url else {
            throw MulgError.infoPlistNotFound
        }

        return BaseApp(appUrl: url)
    }

    /// Returns an array of URLs to MachO files within the app
    static func resolveValidMachOs(_ baseApp: BaseApp) -> [URL] {
        if let validMachOs = baseApp.validMachOs {
            return validMachOs
        }

        nonisolated(unsafe) var resolved: [URL] = [] // Appended only inside serialQueue.sync.
        let serialQueue = DispatchQueue(label: "baseAppUrlResolver")

        baseApp.url.enumerateContents { url, attributes in
            guard attributes.isRegularFile == true, let fileSize = attributes.fileSize, fileSize > 4 else {
                return
            }

            if !url.pathExtension.isEmpty && url.pathExtension != "dylib" {
                return
            }

            let handle = try FileHandle(forReadingFrom: url)

            defer {
                do {
                    try handle.close()
                } catch {
                    print("Failed to close FileHandle for \(url.absoluteString): \(error.localizedDescription)")
                }
            }

            guard let data = try handle.read(upToCount: 4) else {
                return
            }

            // Thin 64-bit, universal and 64-bit universal headers.
            guard MachOBinary.isMachOHeader(data) else { return }
            serialQueue.sync { resolved.append(url) }
        }

        return resolved
    }

    /// Original signing metadata travels with its signed bundle through commit and recovery.
    static func saveEntitlements(_ baseApp: BaseApp) throws {
        let toSave = try Entitlements.dumpEntitlements(exec: baseApp.executable)
        try toSave.store(baseApp.url.appendingPathComponent(BaseApp.originalEntitlementsFileName))
    }

    static func removeMobileProvision(_ baseApp: BaseApp) throws {
        let provision = baseApp.url.appendingPathComponent("embedded.mobileprovision")
        if FileManager.default.fileExists(atPath: provision.path) {
            try FileManager.default.removeItem(at: provision)
        }
    }

    /// Generates a wrapper bundle for an iOS app that allows it to be launched from Finder and other macOS UIs
    /// Games installed in another folder get a link in the library, so launching, keymaps and the
    /// runtime still find them at `Applications/<bundle ID>.app`.
    /// The category of the copy already in the library, or nil for a new game or no category.
    static func installedCategory(of bundleIdentifier: String) -> LSApplicationCategoryType? {
        let plist = AppsVM.appDirectory.appendingEscapedPathComponent(bundleIdentifier + ".app")
            .resolvingSymlinksInPath()
            .appendingPathComponent("Info")
            .appendingPathExtension("plist")
        guard FileManager.default.fileExists(atPath: plist.path) else { return nil }
        let category = AppInfo(contentsOf: plist).applicationCategoryType
        return category == .none ? nil : category
    }

    static func wrap(_ baseApp: BaseApp, into folder: URL = AppsVM.appDirectory) throws -> URL {
        try GameInstaller.place(baseApp.url, bundleIdentifier: baseApp.info.bundleIdentifier,
                                in: folder, library: AppsVM.appDirectory)
    }
}
