//
//  MulgVaultSetupViews.swift
//  Mulg
//
//  Created by Venti on 31/01/2023.
//

import Foundation
import SwiftUI

struct MulgVaultInitialSetupView: View {
    @Binding var isPresented: Bool

    @State private var mulgVaultPassword = ""
    @State private var mulgVaultPasswordConfirmed = ""
    @State private var isEncrypting = false

    @State private var mulgVaultPasswordError = false
    @State private var mulgVaultConfirmError = false

    @State private var keyOption = MulgVaultStatus.disabled

    var body: some View {
        Picker("mulgvault.setup.encryptionKey", selection: $keyOption) {
            Text("mulgvault.setup.useGeneratedKey")
                .tag(MulgVaultStatus.selfGeneratedPassword)
            Text("mulgvault.setup.useUserKey")
                .tag(MulgVaultStatus.userProvidedPassword)
        }
        .pickerStyle(RadioGroupPickerStyle())
        .padding()
        .onChange(of: keyOption) {
            switch keyOption {
            case .selfGeneratedPassword:
                mulgVaultPassword = MulgVaultPassword.shared.generateVerySecurePassword()
                mulgVaultPasswordConfirmed = mulgVaultPassword
            case .userProvidedPassword:
                mulgVaultPassword = ""
                mulgVaultPasswordConfirmed = ""
            case .disabled:
                break
            }
        }

        VStack {
            Group {
                Text("mulgvault.setupPrompt.title")
                    .bold()
                SecureField("mulgvault.masterPassword", text: $mulgVaultPassword)
                SecureField("mulgvault.confirmMasterPassword", text: $mulgVaultPasswordConfirmed)
                if mulgVaultPasswordError {
                    Text("mulgvault.error.blankPassword")
                        .foregroundColor(.red)
                }
                if mulgVaultConfirmError {
                    Text("mulgvault.error.notMatch")
                        .foregroundColor(.red)
                }
            }
            .disabled(keyOption != .userProvidedPassword)
            Divider()
            HStack {
                // Spinner to indicate that data is being encrypted
                if isEncrypting {
                    ProgressView()
                        .padding()
                        .progressViewStyle(.linear)
                }
                Spacer()
                Button("button.Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button("button.OK") {
                    Task {
                        if mulgVaultPassword == "" {
                            mulgVaultPasswordError = true
                            return
                        }
                        if mulgVaultPassword != mulgVaultPasswordConfirmed {
                            mulgVaultConfirmError = true
                            return
                        }
                        Task(priority: .userInitiated) {
                            isEncrypting = true
                            defer { isEncrypting = false }
                            do { try MulgVaultPassword.shared.setMulgVaultPassword(mulgVaultPassword) }
                            catch { Log.shared.error(error); return }
                            switch keyOption {
                            case .userProvidedPassword:
                                MulgVaultPreferences.shared.mulgVaultEnabled = .userProvidedPassword
                            case .selfGeneratedPassword:
                                MulgVaultPreferences.shared.mulgVaultEnabled = .selfGeneratedPassword
                            case .disabled:
                                break
                            }
                            isPresented = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .disabled(isEncrypting)
        .padding()

    }
}

struct MulgVaultUpdatePasswordView: View {
    @Binding var isPresented: Bool

    @State private var oldMulgVaultPassword = MulgVaultPreferences.shared.mulgVaultEnabled == .selfGeneratedPassword ?
                                        MulgVault.shared.mulgVaultPlainTextKey ?? "" : ""
    @State private var mulgVaultPassword = ""
    @State private var mulgVaultPasswordConfirm = ""
    @State private var isWorking = false

    @State private var oldMulgVaultPasswordError = false
    @State private var mulgVaultPasswordError = false
    @State private var mulgVaultPasswordConfirmError = false

    @State private var keyOption = MulgVaultStatus.userProvidedPassword

    var body: some View {
        VStack {
            Text("mulgvault.changePasswordPrompt.title")
                .bold()
            SecureField("mulgvault.oldMasterPassword", text: $oldMulgVaultPassword)
            .disabled(MulgVaultPreferences.shared.mulgVaultEnabled == .selfGeneratedPassword)

            Picker("mulgvault.setup.encryptionKey", selection: $keyOption) {
                Text("mulgvault.setup.useGeneratedKey")
                    .tag(MulgVaultStatus.selfGeneratedPassword)
                Text("mulgvault.setup.useUserKey")
                    .tag(MulgVaultStatus.userProvidedPassword)
            }
            .pickerStyle(RadioGroupPickerStyle())
            .padding()
            .onChange(of: keyOption) {
                switch keyOption {
                case .selfGeneratedPassword:
                    mulgVaultPassword = MulgVaultPassword.shared.generateVerySecurePassword()
                    mulgVaultPasswordConfirm = mulgVaultPassword
                case .userProvidedPassword:
                    mulgVaultPassword = ""
                    mulgVaultPasswordConfirm = ""
                case .disabled:
                    break
                }
            }

            Group {
                SecureField("mulgvault.masterPassword", text: $mulgVaultPassword)
                SecureField("mulgvault.confirmMasterPassword", text: $mulgVaultPasswordConfirm)
                if oldMulgVaultPasswordError {
                    Text("mulgvault.error.incorrectPassword")
                        .foregroundColor(.red)
                        .padding()
                }
                if mulgVaultPasswordError {
                    Text("mulgvault.error.blankPassword")
                        .foregroundColor(.red)
                        .padding()
                }
                if mulgVaultPasswordConfirmError {
                    Text("mulgvault.error.notMatch")
                        .foregroundColor(.red)
                        .padding()
                }
            }
            .disabled(keyOption != .userProvidedPassword)
            Divider()
            HStack {
                if isWorking {
                    ProgressView()
                        .padding()
                        .progressViewStyle(.linear)
                }
                Spacer()
                Button("button.Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button("button.OK") {
                    Task {
                        if !MulgVaultPassword.shared.validatePassword(oldMulgVaultPassword) {
                            oldMulgVaultPasswordError = true
                            return
                        }
                        if mulgVaultPassword == "" {
                            mulgVaultPasswordError = true
                            return
                        }
                        if mulgVaultPassword != mulgVaultPasswordConfirm {
                            mulgVaultPasswordConfirmError = true
                            return
                        }
                        Task(priority: .userInitiated) {
                            isWorking = true
                            defer { isWorking = false }
                            do { try MulgVaultPassword.shared.setMulgVaultPassword(mulgVaultPassword) }
                            catch { Log.shared.error(error); return }
                            switch keyOption {
                            case .userProvidedPassword:
                                MulgVaultPreferences.shared.mulgVaultEnabled = .userProvidedPassword
                            case .selfGeneratedPassword:
                                MulgVaultPreferences.shared.mulgVaultEnabled = .selfGeneratedPassword
                            case .disabled:
                                break
                            }
                            isPresented = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .disabled(isWorking)
        .padding()
    }
}

struct MulgVaultRemovalView: View {
    @Binding var isPresented: Bool

    @State private var mulgVaultPassword = MulgVaultPreferences.shared.mulgVaultEnabled == .selfGeneratedPassword ?
                                    MulgVault.shared.mulgVaultPlainTextKey ?? "" : ""
    @State private var isWorking = false

    @State private var mulgVaultPasswordError = false

    @State private var keyOption = MulgVaultPreferences.shared.mulgVaultEnabled

    var body: some View {
        VStack {
            Text("mulgvault.removePrompt.title")
                .bold()
            SecureField("mulgvault.masterPassword", text: $mulgVaultPassword)
            .disabled(keyOption == .selfGeneratedPassword)
            if mulgVaultPasswordError {
                Text("mulgvault.error.incorrectPassword")
                    .foregroundColor(.red)
                    .padding()
            }
            Divider()
            HStack {
                if isWorking {
                    ProgressView()
                        .padding()
                        .progressViewStyle(.linear)
                }
                Spacer()
                Button("button.Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button("button.OK") {
                    Task {
                        if !MulgVaultPassword.shared.validatePassword(mulgVaultPassword) {
                            mulgVaultPasswordError = true
                            return
                        }
                        Task(priority: .userInitiated) {
                            isWorking = true
                            MulgVaultPassword.shared.removeMulgVaultPassword()
                            isWorking = false
                            isPresented = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .disabled(isWorking)
        .padding()
    }
}
