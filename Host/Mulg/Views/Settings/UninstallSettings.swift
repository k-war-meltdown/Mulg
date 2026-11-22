//
//  UninstallSettings.swift
//  Mulg
//
//  Created by TheMoonThatRises on 9/26/22.
//

import SwiftUI

class UninstallPreferences: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = UninstallPreferences()

    @objc @AppStorage("ClearAppDataUninstall") var clearAppData = false
    @objc @AppStorage("RemoveAppKeymapUninstall") var removeAppKeymap = false
    @objc @AppStorage("RemoveAppSettingUninstall") var removeAppSettings = false
    @objc @AppStorage("RemoveAppEntitlementsUninstall") var removeAppEntitlements = false
    @objc @AppStorage("RemoveMulgChainUninstall") var removeMulgChain = false

    @AppStorage("ShowUninstallPopup") var showUninstallPopup = true
}

struct UninstallSettings: View {
    public static var shared = UninstallSettings()

    @ObservedObject var uninstallPreferences = UninstallPreferences.shared

    @State private var showPruneFileAlert = false

    var body: some View {
        Form {
            Text("preferences.whenUninstalling")
            GroupBox {
                HStack {
                    VStack(alignment: .leading) {
                        Toggle("preferences.toggle.showUninstall",
                               isOn: $uninstallPreferences.showUninstallPopup)
                        Toggle("preferences.toggle.clearAppData",
                               isOn: $uninstallPreferences.clearAppData)
                        Toggle("preferences.toggle.removeKeymap",
                               isOn: $uninstallPreferences.removeAppKeymap)
                        Toggle("preferences.toggle.removeSetting",
                               isOn: $uninstallPreferences.removeAppSettings)
                        Toggle("preferences.toggle.removeEntitlements",
                               isOn: $uninstallPreferences.removeAppEntitlements)
                        Toggle("preferences.toggle.removeMulgChain",
                               isOn: $uninstallPreferences.removeMulgChain)
                    }
                    Spacer()
                }
            }
            Spacer()
                .frame(height: 20)
            Button("preferences.button.pruneFiles") {
                showPruneFileAlert.toggle()
            }
            .alert("preferences.prune.alert", isPresented: $showPruneFileAlert, actions: {
                Button("preferences.button.pruneFiles", role: .destructive) {
                    Uninstaller.pruneFiles()
                }
                Button("button.Cancel", role: .cancel) {
                    showPruneFileAlert.toggle()
                }
                .keyboardShortcut(.defaultAction)
            }, message: {
                Text("preferences.prune.message")
            })
            Button("Retry Incomplete Removals") {
                Task { await Uninstaller.retryIncompleteRemovalsPopup() }
            }
            .help("Finishes a Remove Game and All Data that stopped at a disconnected drive or a refused deletion.")
        }
        .padding(30)
        .frame(width: 600, height: 270, alignment: .center)
    }
}
