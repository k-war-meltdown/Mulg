//
//  VersionCheck.swift
//  Mulg
//
//  Created by Edoardo C. on 30/04/25.
//

import MulgStore

class VersionCheck: @unchecked Sendable {
    static let shared = VersionCheck()
    @MainActor
    func checkUpdateAlert(app: SourceAppsData) async -> Bool {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("alert.version.title", comment: "")
        alert.informativeText = String(
            format: NSLocalizedString("alert.version.text", comment: ""), "\(app.name)"
        )
        alert.icon = NSImage(
            systemSymbolName: "square.and.arrow.down.fill",
            accessibilityDescription: nil
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("alert.start.anyway", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("ipaLibrary.download", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("button.Cancel", comment: ""))
        let result = alert.runModal()
        switch result {
        case .alertFirstButtonReturn:
            return false
        case .alertSecondButtonReturn:
            if let url = URL(string: app.link) {
                if DownloadVM.shared.inProgress {
                    Log.shared.error(MulgError.waitDownload)
                } else {
                    DownloadApp(url: await RedirectHandler.resolve(url), app: app, warning: nil).start()
                }
            }
            return true
        default:
            return true
        }
    }

    func checkNewVersion(myApp: MulgGame) async -> Bool {
        // Launching waits at most 2 s for the store; the update offer then comes next launch.
        await StoreVM.shared.awaitResolveSources(upTo: .seconds(2))
        // Every source is asked, and the newest offer wins. "2.0" is no update over "2".
        let offers = StoreVM.shared.sourcesApps.filter { $0.bundleID == myApp.info.bundleIdentifier }
        if let newest = GameUpdates.newest(installed: myApp.info.bundleVersion, offered: offers.map(\.version)),
           let app = offers.first(where: { $0.version == newest }) {
            return await checkUpdateAlert(app: app)
        }
        return false
    }
}
