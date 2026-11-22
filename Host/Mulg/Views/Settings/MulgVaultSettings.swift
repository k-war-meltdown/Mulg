//
//  MulgVaultSettings.swift
//  Mulg
//
//  Created by Venti on 31/01/2023.
//

import SwiftUI

enum MulgVaultStatus: String, Codable, Hashable {
    case disabled
    case selfGeneratedPassword
    case userProvidedPassword
}

class MulgVaultPreferences: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = MulgVaultPreferences()

    @AppStorage("mulgVaultEnabled") var mulgVaultEnabled: MulgVaultStatus = MulgVaultStatus.disabled
    @AppStorage("promptForMulgVaultPasswordAtLaunch") var promptForMulgVaultPasswordAtLaunch = true
}

struct MulgVaultSettings: View {
    static let shared = MulgVaultSettings()

    @State private var mulgVaultInitialSetupShown = false
    @State private var mulgVaultUpdatePasswordShown = false
    @State private var mulgVaultRemovalViewShown = false

    @ObservedObject var mulgVaultPreferences = MulgVaultPreferences.shared
    @ObservedObject var mulgVaultObserved = MulgVaultObservable.shared

    @ObservedObject var modifierKeyObserver = ModifierKeyObserver.shared

    var body: some View {
        VStack {
            HStack {
                HStack {
                    Text("mulgvault.status.title")
                    Text(mulgVaultObserved.mulgVaultEnabled ?
                             MulgVaultPreferences.shared.mulgVaultEnabled == .selfGeneratedPassword ?
                             "mulgvault.status.managedPassword" : "mulgvault.status.userPassword"
                         : "state.disabled")
                        .foregroundColor(mulgVaultObserved.mulgVaultEnabled ? .green : .none)
                    Spacer()
                }
                Spacer()
                Button(mulgVaultObserved.mulgVaultEnabled ? "button.Reset" : "button.Enable") {
                    if mulgVaultObserved.mulgVaultEnabled {
                        if modifierKeyObserver.isOptionKeyPressed {
                            MulgVaultPassword.shared.forceResetMulgVaultPassword()
                        } else {
                            mulgVaultRemovalViewShown = true
                        }
                    } else {
                        mulgVaultInitialSetupShown = true
                    }
                }
                .foregroundColor((mulgVaultObserved.mulgVaultEnabled
                                 && modifierKeyObserver.isOptionKeyPressed)
                                    ? .red : .none)
            }
            .padding()
            Spacer()
            HStack {
                VStack(alignment: .leading) {
                    Text("mulgvault.status.chainCount")
                    Text(String(format: NSLocalizedString("mulgvault.status.unlockedCount %@ %@", comment: ""),
                                "\(mulgVaultObserved.unlockedCount)",
                                "\(mulgVaultObserved.keychains.count)"))
                }
                Spacer()
                Button("mulgvault.button.lockAll") {
                    MulgVault.shared.lockAllChainsAsync()
                }
                .disabled(!mulgVaultObserved.mulgVaultEnabled)
            }
            .padding()
            HStack {
                Spacer()
                Button("mulgvault.button.changePassword") {
                    mulgVaultUpdatePasswordShown = true
                }
                .disabled(!mulgVaultObserved.mulgVaultEnabled)
                Spacer()
            }
            .padding()
            VStack(alignment: .leading) {
                Toggle("mulgvault.toggle.startupPrompt", isOn: $mulgVaultPreferences.promptForMulgVaultPasswordAtLaunch)
                    .help("mulgvault.toggle.startupPrompt.help")
                Text("The vault password and every game's login key are sealed by this Mac's Secure Enclave in Mulg's own files. Nothing is kept in your macOS Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding()
        }
        .frame(width: 600, height: 330)
        .sheet(isPresented: $mulgVaultInitialSetupShown) {
            MulgVaultInitialSetupView(isPresented: $mulgVaultInitialSetupShown)
        }
        .sheet(isPresented: $mulgVaultUpdatePasswordShown) {
            MulgVaultUpdatePasswordView(isPresented: $mulgVaultUpdatePasswordShown)
        }
        .sheet(isPresented: $mulgVaultRemovalViewShown) {
            MulgVaultRemovalView(isPresented: $mulgVaultRemovalViewShown)
        }
    }
}

struct MulgVaultSettings_Previews: PreviewProvider {
    static var previews: some View {
        MulgVaultSettings()
    }
}
