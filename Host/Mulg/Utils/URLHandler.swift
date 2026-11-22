//
//  URLHandler.swift
//  Mulg
//
//  Created by Venti on 14/02/2023.
//

import Foundation
import MulgGUI
import MulgContracts
import MulgLibrary

enum URLTypes: Int, Equatable {
    case source
    case keymap
    case app
}

enum URLAction: Int, Equatable {
    case add
    case remove
    case update
    case install
    case open
}

class URLObservable: ObservableObject, @unchecked Sendable {
    @Published var url: String?
    @Published var type: URLTypes?
    @Published var action: URLAction?

    public static let shared = URLObservable()
}

@MainActor
struct URLHandler {
    public static let shared = URLHandler()

    func processURL(url: URL) {
        guard let urlComponenents = NSURLComponents(url: url, resolvingAgainstBaseURL: false),
              let uriHost = urlComponenents.host,
              let params = urlComponenents.queryItems else {
                // Fall back to old url handler (for files)
                if url.pathExtension == "ipa" {
                    Installer.install(ipaUrl: url, export: false, returnCompletion: { installed in
                    Task { @MainActor in
                        AppsVM.shared.fetchApps()
                        guard installed != nil else { return }
                        NotifyService.shared.notify(
                            NSLocalizedString("notification.appInstalled", comment: ""),
                            NSLocalizedString("notification.appInstalled.message", comment: "")
                        )
                    }})
                }
                return
            }
        // URI format: mulgapp://<object>?action=<action>&<param>=<value>
        // Example: mulgapp://source?action=add&url=https://example.com/source.json
        // Switch case for main uri path
        switch uriHost {
        case "source":
            processSourceURL(params: params)
        case "app":
            guard url.scheme == "mulgapp", params.filter({ $0.name == "action" }).count == 1,
                  params.first(where: { $0.name == "action" })?.value == "open",
                  params.filter({ $0.name == "id" }).count == 1,
                  let identifier = params.first(where: { $0.name == "id" })?.value else { return }
            let profileName = params.first(where: { $0.name == "profile" })?.value
            let profile = profileName.flatMap(PerformanceProfile.init(argument:))
            guard profileName == nil || profile != nil else { return }
            Task { @MainActor in
                do {
                    if BundleTransaction.hasPendingRecovery(identifier) {
                        let lease = try GameSessionLease(bundleIdentifier: identifier)
                        defer { withExtendedLifetime(lease) {} }
                        try BundleTransaction.recover(identifier)
                    }
                    await AppsVM.shared.fetchApps().value
                    guard let app = AppsVM.shared.apps.first(where: { $0.info.bundleIdentifier == identifier }) else { return }
                    if let profile { _ = try GameActions().applyProfile(profile, to: identifier) }
                    _ = await app.launch(preferGamesCategory: profile == .fps120)
                } catch { Log.shared.error(error) }
            }
        default:
            // Print URL to log and break
            NSLog("Unknown URL: \(url)")
        }
    }

    func processSourceURL(params: [URLQueryItem]) {
        // Make dang sure we have the params we need and they match expected query items
        guard params.count == 2,
              params[0].name == "action",
              params[1].name == "url" else {
            // Print params to logs and break
            NSLog("Unknown source URL params: \(params)")
            return
        }

        if let actionParam = params[0].value {
            URLObservable.shared.type = .source
            switch actionParam {
            case "add":
                // Add source
                if let url = params[1].value {
                    URLObservable.shared.url = url
                    URLObservable.shared.action = .add
                }
            case "remove":
                // Remove source
                if let url = params[1].value {
                    URLObservable.shared.url = url
                    URLObservable.shared.action = .remove
                }
            case "update":
                // Update source
                if let url = params[1].value {
                    URLObservable.shared.url = url
                    URLObservable.shared.action = .update
                }
            default:
                // Print params to console and break
                print("Unknown source URL params: \(params)")
            }
        }
    }
}
