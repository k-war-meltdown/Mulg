//
//  Downloader.swift
//  Mulg
//
//  Created by Amir Mohammadi on 9/26/1401 AP.
//

import Foundation
@preconcurrency import DownloadManager

/// DownloaderManager can be configured through this struct, default values are as the same as below
/// `public struct DownloadManagerConfig {`
///    `public var maximumRetries = 3`
///    `public var exponentialBackoffMultiplier = 10`
///    `public var usesNotificationCenter = false`
///    `public var showsLocalNotifications = false`
///    `public var logVerbosity: LogVerbosity = .none
/// `}`
///  Use `downloader.configuration = DownloadManagerConfig()` in
///  `DownloadApp` class before `downloader.addDownload` to apply
///  More details: https://github.com/shapedbyiris/download-manager/blob/master/README.md

// ponytail: unchecked, DownloadManager.shared is a vendor class with no Sendable marking.
final class DownloadApp: @unchecked Sendable {
    let url: URL?
    let app: SourceAppsData?
    let warning: String?

    init(url: URL?, app: SourceAppsData?, warning: String?) {
        self.url = url
        self.app = app
        self.warning = warning
    }

    let downloadVM = DownloadVM.shared
    let installVM = InstallVM.shared
    let downloader = DownloadManager.shared

    @MainActor
    func start() {
        if installVM.inProgress {
            Log.shared.error(MulgError.waitInstallation)
        } else {
            if let app = app, MulgGame.PROHIBITED_APPS.contains(app.bundleID) {
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("alert.error", comment: "")
                alert.informativeText = String(
                    format: NSLocalizedString("error.appProhibited", comment: ""),
                    arguments: [app.name]
                )
                alert.alertStyle = .warning
                alert.addButton(withTitle: NSLocalizedString("Ok", comment: ""))
                alert.addButton(withTitle: NSLocalizedString("alert.download.downloadAnyway", comment: ""))
                if alert.runModal() == .alertFirstButtonReturn {
                    return
                }
            }

            if let warningMessage = warning, let app = app {
                let alert = NSAlert()
                alert.messageText = NSLocalizedString(warningMessage, comment: "")
                alert.informativeText = String(
                    format: NSLocalizedString("alert.install.anyway", comment: ""),
                    arguments: [app.name]
                )
                alert.alertStyle = .warning
                alert.addButton(withTitle: NSLocalizedString("button.Yes", comment: ""))
                alert.addButton(withTitle: NSLocalizedString("button.No", comment: ""))

                if alert.runModal() == .alertSecondButtonReturn {
                    return
                }
            }
            if let url = url, let app = app {
                let ipa = IPA(url: url)
                Task {
                    if await ipa.checkOfficialMacOS(app: IPA.Application.store(app)) {
                        cancel()
                    } else {
                        if url.isFileURL {
                            proceedInstall(url, deleteIPA: false)
                        } else {
                            let (finalURL, urlIsValid) = await NetworkVM.urlAccessible(url: url, popup: true)
                            if urlIsValid, let newWrappedURL = finalURL {
                                proceedDownload(newWrappedURL)
                            }
                        }
                    }
                }
            }
        }
    }

    func cancel() {
        downloader.cancelAllDownloads()

        downloadVM.next(.canceled, 0.95, 1.0)
        downloadVM.storeAppData = nil
    }

    private func proceedDownload(_ finalURL: URL) {
        self.downloadVM.storeAppData = self.app
        self.downloadVM.next(.downloading, 0.0, 0.7)

        var tmpDir: URL?
        do {
            tmpDir = try FileManager.default.url(for: .itemReplacementDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: URL(fileURLWithPath: "/Users"),
                                                 create: true)

            if let tmpDir = tmpDir {
                downloader.addDownload(url: finalURL,
                                       destinationURL: tmpDir,
                                       onProgress: { progress in
                    // progress is a Float
                    self.downloadVM.progress = Double(progress)
                }, onCompletion: { error, fileURL in
                    self.downloadVM.next(.integrity, 0.7, 0.95)

                    if let error = error {
                        self.downloadVM.next(.failed, 0.95, 1.0)
                        self.downloadVM.storeAppData = nil
                        FileManager.default.delete(at: tmpDir)
                        return Log.shared.error(error)
                    }

                    self.verifyChecksum(checksum: self.downloadVM.storeAppData?.checksum, file: fileURL) { completing in
                        self.downloadVM.next(completing ? .finish : .failed, 0.95, 1.0)
                        if completing {
                            Task { @MainActor in
                                self.proceedInstall(fileURL)
                            }
                        } else {
                            // A rejected download is gigabytes left in the temporary folder.
                            FileManager.default.delete(at: tmpDir)
                        }
                    }
                })
            }
        } catch {
            self.downloadVM.next(.failed, 0.95, 1.0)

            if let tmpDir = tmpDir {
                FileManager.default.delete(at: tmpDir)
            }
            Log.shared.error(error)
        }
    }

    private func verifyChecksum(checksum: String?, file: URL?, completion: @escaping @Sendable (Bool) -> Void) {
        Task {
            if let originalSum = checksum, !originalSum.isEmpty, let fileURL = file {
                // Sources publish hex in either case.
                if let sha256 = fileURL.sha256, originalSum.lowercased() != sha256 {
                    checksumAlert(originalSum: originalSum, givenSum: sha256, completion: completion)
                    return
                }
            }

            completion(true)
        }
    }

    private func checksumAlert(originalSum: String, givenSum: String, completion: @escaping @Sendable (Bool) -> Void) {
        Task { @MainActor in
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("mulggame.download.differentChecksum", comment: "")
            alert.informativeText = String(
                format: NSLocalizedString("mulggame.download.differentChecksumDesc", comment: ""),
                arguments: [originalSum, givenSum]
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: NSLocalizedString("button.Proceed", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("button.Cancel", comment: ""))

            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    @MainActor private func proceedInstall(_ url: URL?, deleteIPA: Bool = true) {
        if let url = url {
            Installer.install(ipaUrl: url, export: false, returnCompletion: { installed in
                Task { @MainActor in
                    self.downloadVM.storeAppData = nil
                    AppsVM.shared.fetchApps()
                    guard installed != nil else { return }
                    if deleteIPA {
                        FileManager.default.delete(at: url)
                    }
                    StoreVM.shared.resolveSources()
                    NotifyService.shared.notify(
                        NSLocalizedString("notification.appInstalled", comment: ""),
                        NSLocalizedString("notification.appInstalled.message", comment: ""))
                }
            })
        }
    }
}
