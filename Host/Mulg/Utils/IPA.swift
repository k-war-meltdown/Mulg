//
//  IPA.swift
//  Mulg
//

import Foundation
@preconcurrency import SwiftSoup

public class IPA: @unchecked Sendable {
    public let url: URL
    public private(set) var tmpDir: URL?

    public init(url: URL) {
        self.url = url
    }

    public func allocateTempDir() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mulg-IPA-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        tmpDir = directory
    }

    public func releaseTempDir() {
        guard let workDir = tmpDir else {
            return
        }

        FileManager.default.delete(at: workDir)

        tmpDir = nil
    }

    public func removeQuarantine(_ execUrl: URL) throws {
        try Shell.run("/usr/bin/xattr", "-r", "-d", "com.apple.quarantine", execUrl.relativePath)
    }

    /// An IPA whose archive data is broken: the files are named, as they are inside the app.
    struct DamagedArchive: LocalizedError {
        let files: [String]
        /// Every problem was a checksum: all files were unpacked (the damaged ones incomplete), so the
        /// player may install anyway (`unpackedApp`).
        let canInstallAnyway: Bool

        /// The damaged files, at most three named.
        var fileList: String {
            files.prefix(3).joined(separator: ", ") + (files.count > 3 ? " and \(files.count - 3) more" : "")
        }

        var errorDescription: String? {
            "This IPA file is damaged: \(fileList) failed its checksum while unpacking, so part of the game's data "
                + "is missing. The file itself is broken (an incomplete download or a bad copy); download the IPA "
                + "again, from another source if this one keeps failing."
        }
    }

    /// Unpacks the IPA. unzip's exit status decides, not its output: 0 is success and 1 means warnings
    /// only, with every file extracted (any output used to fail the install). A checksum failure names
    /// the damaged files instead of showing unzip's text with the temporary path.
    public func unzip() throws -> BaseApp {
        guard let workDir = tmpDir else { throw MulgError.appCorrupted }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-oq", url.path, "-d", workDir.path]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: try pipe.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
        process.waitUntilExit()
        switch process.terminationStatus {
        case 0:
            break
        case 1:
            Log.shared.log("IPA unpacked with warnings: \(output)")
        default:
            let lines = output.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let damaged = lines.compactMap { line -> String? in
                guard let range = line.range(of: " bad CRC") else { return nil }
                // unzip prints the temporary folder as /private/var/…, not /var/…: cut at Payload/.
                let path = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                if let payload = path.range(of: "Payload/") { return String(path[payload.upperBound...]) }
                return path
            }
            Log.shared.log("IPA unpacking failed (unzip \(process.terminationStatus)): \(output)", isError: true)
            if !damaged.isEmpty {
                // unzip still writes a file that fails its checksum; with nothing else wrong (its own
                // summary line aside) every file is on disk.
                let otherProblems = lines.contains { !$0.contains(" bad CRC") && !$0.hasPrefix("At least one error was detected") }
                throw DamagedArchive(files: damaged, canInstallAnyway: !otherProblems)
            }
            // "(disk full?)" and the rest keep their existing alerts (Installer.returnErrorString).
            throw output.isEmpty ? "unzip failed with status \(process.terminationStatus)" : output
        }
        return try unpackedApp()
    }

    /// The app unpacked by `unzip`, also after the player chose to install a damaged IPA anyway.
    public func unpackedApp() throws -> BaseApp {
        guard let workDir = tmpDir else { throw MulgError.appCorrupted }
        return try Installer.fromIPA(detectingAppNameInFolder: workDir.appendingPathComponent("Payload"))
    }

    func packIPABack(app: URL) throws -> URL {
        let payload = app.deletingPathExtension().deletingLastPathComponent()
        let name = app.deletingPathExtension().lastPathComponent

        let newIpa = getDocumentsDirectory()
            .appendingEscapedPathComponent(name)
            .appendingPathExtension("ipa")

        // ditto keeps "Payload/" at the archive root (zip -r stored the absolute temp path) and
        // replaces an older export instead of adding to it.
        try Shell.run("/usr/bin/ditto", "-c", "-k", "--norsrc", "--noextattr", "--keepParent",
                      payload.path, newIpa.path)

        return newIpa
    }

    private func getDocumentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]
        return documentsDirectory
    }

    enum Application {
        case base(BaseApp)
        case store(SourceAppsData)
    }

    private func checkMacOSCompatibility(appID: Int) async -> Bool {
        let urlString = "https://apps.apple.com/us/app/id\(appID)"
        guard let url = URL(string: urlString) else {
            return false
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return false
            }

            guard let htmlString = String(data: data, encoding: .utf8) else {
                return false
            }
            let document = try SwiftSoup.parse(htmlString)
            let elements = try document.getElementsByClass("information-list__item__definition__item__definition")
            for element in elements {
                let text = try element.text()
                if text.contains("macOS") {
                    return true
                }
            }
        } catch {
            return false
        }

        return false
    }

    @MainActor
    func checkOfficialMacOS(app: Application) async -> Bool {
        // With the popup off the answer is always "go on", so skip the two App Store requests.
        guard InstallPreferences.shared.showAppStorePopup else {
            return false
        }
        let bundleID: String
        let appID: Int
        switch app {
        case .base(let base):
            bundleID = base.info.bundleIdentifier
            let urlString = "https://itunes.apple.com/lookup?bundleId=\(bundleID)"
            let itunes: ITunesResponse? = await getITunesData(urlString)
            appID = itunes?.results.first?.trackId ?? 0
        case .store(let store):
            bundleID = store.bundleID
            let appLookup = store.itunesLookup
            let stringArray = appLookup.components(separatedBy: CharacterSet.decimalDigits.inverted)
            appID = Int(stringArray.last ?? "0") ?? 0
        }
        let supportMacOS: Bool = await checkMacOSCompatibility(appID: appID)
        let showAlert = InstallPreferences.shared.showAppStorePopup
        if showAlert && supportMacOS {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("alert.appstore", comment: "")
            alert.informativeText = String(
                format: NSLocalizedString("macos.version", comment: "")
            )
            alert.icon = nil
            alert.showsSuppressionButton = true
            alert.suppressionButton?.toolTip = NSLocalizedString("alert.supression", comment: "String")
            alert.alertStyle = .informational
            alert.addButton(withTitle: NSLocalizedString("alert.install.anyway", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("alert.open.appstore", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("button.Cancel", comment: ""))
            let result = alert.runModal()
            switch result {
            case .alertFirstButtonReturn:
                if let suppressionButton = alert.suppressionButton,
                   suppressionButton.state == .on {
                    InstallPreferences.shared.showAppStorePopup = false
                }
                return false
            case .alertSecondButtonReturn:
                if appID != 0 {
                    guard let urlApp = URL(string:
                                            "itms-apps://apps.apple.com/app/id\(appID)")
                    else {return true}
                    NSWorkspace.shared.open(urlApp)
                }
                return true
            default:
                return true
            }
        }
        return false
    }
}
