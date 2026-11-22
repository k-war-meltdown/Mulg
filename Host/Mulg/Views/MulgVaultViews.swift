//
//  MulgVaultViews.swift
//  Mulg
//
//  Created by Venti on 01/02/2023.
//

import SwiftUI

struct MulgVaultUnlockingPrompt: View {
    @State private var password = ""
    @State private var passwordError = false

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Image(systemName: "lock")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                Text("mulgvault.unlockPrompt.title")
                    .padding()
            }
            .padding()
                SecureField("mulgvault.masterPassword", text: $password)
                    .padding()
                if passwordError {
                    Text("mulgvault.error.incorrectPassword")
                        .foregroundColor(.red)
                        .padding()
            }
            Divider()
            HStack {
                Spacer()
                Button("button.Cancel") {
                    MulgVaultObservable.shared.isMulgVaultUnlockingPromptShown = false
                }
                .keyboardShortcut(.cancelAction)
                Button("button.Unlock") {
                    unlock()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }

    func unlock() {
        if MulgVaultPassword.shared.validatePassword(password) {
            // if Smart Unlock is enabled, store the masterKey
            MulgVault.shared.mulgVaultPlainTextKey = password
        } else {
            passwordError = true
            return
        }
        MulgVaultObservable.shared.isMulgVaultUnlockingPromptShown = false
    }
}
