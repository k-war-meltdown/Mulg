//
//  AppIntegrity.swift
//  Mulg
//

import Foundation

class AppIntegrity: ObservableObject {

    @Published var integrityOff: Bool = !AppIntegrity.insideAppsFolder

    func verifyAppIntegrity() {
        integrityOff = !AppIntegrity.insideAppsFolder
    }

    func moveToApps() {
        do {
            if let url = AppIntegrity.appUrl {
                FileManager.default.delete(at: AppIntegrity.expectedUrl)
                try FileManager.default.copyItem(at: url, to: AppIntegrity.expectedUrl)
                URL(fileURLWithPath: AppIntegrity.expectedUrl.path).openInFinder()
                FileManager.default.delete(at: url)
                    exit(0)
                }
            } catch {
                Log.shared.error(error)
        }
    }

    private static var appUrl: URL? {
        Bundle.main.resourceURL?.deletingLastPathComponent().deletingLastPathComponent()
    }

    private static let expectedUrl = URL(fileURLWithPath: "/Applications/Mulg.app")

    private static var insideAppsFolder: Bool {
        guard let url = appUrl?.standardizedFileURL.resolvingSymlinksInPath() else { return false }
        // An external volume's Applications folder is a valid permanent install location.
        return url.path.contains("Xcode")
            || (url.lastPathComponent == "Mulg.app"
                && url.deletingLastPathComponent().lastPathComponent == "Applications")
    }

}
