//
//  MulgSettingsView.swift
//  Mulg
//
//  Created by Andrew Glaze on 7/16/22.
//

import MulgGUI
@preconcurrency import Sparkle
import SwiftUI

/// The app's own settings (⌘,), in three groups: the app itself, installing and removing games,
/// and the login vault.
struct MulgSettingsView: View {
    @ObservedObject var updaterViewModel: UpdaterViewModel

    private enum Page: String, CaseIterable, Identifiable {
        case general = "General", updates = "Updates", about = "About"
        case install = "Installing games", uninstall = "Removing games"
        case vault = "Login vault"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: "gearshape"; case .updates: "arrow.down.circle"; case .about: "info.circle"
            case .install: "arrow.down.app"; case .uninstall: "trash"; case .vault: "key"
            }
        }
        var tint: Color {
            switch self {
            case .general: MulgIconTint.gray; case .updates: MulgIconTint.blue; case .about: MulgIconTint.accent
            case .install: MulgIconTint.green; case .uninstall: MulgIconTint.red; case .vault: MulgIconTint.indigo
            }
        }
        var subtitle: String {
            switch self {
            case .general: "Appearance, the profile new games start with, and the menu-bar icon."
            case .updates: "Keep Mulg itself up to date."
            case .about: "Version, credits and licences."
            case .install: "Where new games go and what they start with."
            case .uninstall: "What is removed with a game."
            case .vault: "MulgVault keeps games' saved logins encrypted on this Mac."
            }
        }
        static let groups: [(String, [Page])] = [
            ("Mulg", [.general, .updates, .about]),
            ("Games", [.install, .uninstall]),
            ("Security", [.vault])
        ]
    }

    @State private var selection: Page? = .general
    private var page: Page { selection ?? .general }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(Page.groups, id: \.0) { title, pages in
                    Section(title) {
                        ForEach(pages) { item in
                            Label { Text(item.rawValue) } icon: { MulgIcon(item.symbol, tint: item.tint, size: 20) }
                                .tag(item)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 200)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    MulgIcon(page.symbol, tint: page.tint, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(page.rawValue).font(.title2.weight(.semibold))
                        Text(page.subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 8)
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 820, height: 620)
        .mulgAppearance()
        .mulgWindowBackground()
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .general: GeneralSettings()
        case .updates: UpdateSettings(updaterViewModel: updaterViewModel)
        case .vault: MulgVaultSettings.shared
        case .install: InstallSettings.shared
        case .uninstall: UninstallSettings.shared
        case .about: AboutSettings()
        }
    }
}
