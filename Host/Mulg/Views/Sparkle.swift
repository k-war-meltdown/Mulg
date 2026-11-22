//
//  Sparkle.swift
//  Mulg
//
//  Created by Andrew Glaze on 7/17/22.
//  Copied from https://sparkle-project.org/documentation/programmatic-setup/
//

@preconcurrency import Sparkle
import SwiftUI

// This view model class manages Sparkle's updater and publishes when new updates are allowed to be checked
@MainActor
final class UpdaterViewModel: ObservableObject {
    private let updaterController: SPUStandardUpdaterController

    @Published var canCheckForUpdates = false

    var automaticallyCheckForUpdates: Bool {
        get {
            updaterController.updater.automaticallyChecksForUpdates
        }
        set(newValue) {
            updaterController.updater.automaticallyChecksForUpdates = newValue
        }
    }

    init() {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        let hasFeed = feed.flatMap(URL.init(string:))?.scheme == "https" && !(key?.isEmpty ?? true)
        updaterController = SPUStandardUpdaterController(
            startingUpdater: hasFeed,
            updaterDelegate: nil,
            userDriverDelegate: nil)

        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)

        if hasFeed, automaticallyCheckForUpdates {
            updaterController.updater.checkForUpdatesInBackground()
        }
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}

// This additional view is needed for the disabled state on the menu item to work properly before Monterey.
// See https://stackoverflow.com/questions/68553092/menu-not-updating-swiftui-bug for more information
struct CheckForUpdatesView: View {
    @ObservedObject var updaterViewModel: UpdaterViewModel

    var body: some View {
        Button(NSLocalizedString("menubar.checkForUpdates", comment: ""),
               systemImage: "arrow.trianglehead.2.clockwise.rotate.90",
               action: updaterViewModel.checkForUpdates)
            .disabled(!updaterViewModel.canCheckForUpdates)
    }
}
