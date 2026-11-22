#if os(macOS) && !targetEnvironment(macCatalyst)
import MulgContracts
import MulgLibrary
import SwiftUI

/// The Privacy page of a game's settings: what the game may use. Off answers the game "denied"
/// the way an iPad does after "Don't Allow", before macOS shows a dialog, so nothing is asked.
public struct GamePrivacyTab: View {
    let bundleIdentifier: String
    let saved: () -> Void

    public init(bundleIdentifier: String, saved: @escaping () -> Void) {
        self.bundleIdentifier = bundleIdentifier
        self.saved = saved
    }

    public var body: some View {
        GameSettingsFile(bundleIdentifier: bundleIdentifier, saved: saved) { settings in
            Form {
                Section {
                    toggle("Microphone", "mic", settings.mulg.privacy.microphone, key: "mulg.privacy.microphone")
                    toggle("Camera", "camera", settings.mulg.privacy.camera, key: "mulg.privacy.camera")
                    toggle("Photos", "photo.on.rectangle", settings.mulg.privacy.photos, key: "mulg.privacy.photos")
                    toggle("Location", "location", settings.mulg.privacy.location, key: "mulg.privacy.location")
                } header: {
                    Text("What the game may use", bundle: .module)
                } footer: {
                    Text("Off: the game is told \"denied\", as on an iPad after Don't Allow, and macOS never asks. On: the game may ask macOS once. Ad tracking is always denied. A Mac without a microphone always answers \"denied\" for the microphone.", bundle: .module)
                }
                logins(settings)
                Section {
                    Toggle(isOn: settings.mulg.controls.automaticHUDAnchoring) {
                        Label {
                            OptionLabel("Screen recording for HUD anchoring", .live, key: "mulg.controls.automaticHUDAnchoring", owner: .controls)
                        } icon: { Image(systemName: "rectangle.dashed.badge.record") }
                    }
                } header: {
                    Text("Screen recording", bundle: .module)
                } footer: {
                    Text("Automatic HUD anchoring looks at the game window to line controls up with its buttons, which needs Screen Recording. Mulg asks macOS once per game; if you decline, it never asks again and controls use the keymap layout.", bundle: .module)
                }
            }
            .formStyle(.grouped)
        }
    }

    /// Where the game's logins live and what it can never reach (2026-10-10): Mulg's own keychain, sealed by
    /// this Mac's Secure Enclave, and a sandbox that walls off the macOS Keychain and everything not the game's.
    private func logins(_ settings: Binding<GameSettings>) -> some View {
        let saves = settings.wrappedValue.mulgChain
        let migration = GameSandboxAccess.migrationState(for: bundleIdentifier, savesLogins: saves)
        let attention = migration == .notStarted || migration == .pending || migration == .stuck
        return Section {
            Toggle(isOn: settings.mulgChain) {
                Label {
                    OptionLabel(String(localized: "Save logins", bundle: .module), .restart, key: "mulgChain", owner: .integrations)
                } icon: { Image(systemName: "key") }
            }
            LabeledContent {
                Text(saves ? String(localized: "Mulg's own keychain, sealed to this Mac", bundle: .module)
                           : String(localized: "Memory only, until the game quits", bundle: .module))
                    .foregroundStyle(.secondary)
            } label: { Label(String(localized: "Logins kept in", bundle: .module), systemImage: "lock.shield") }
            LabeledContent {
                Text(Self.keychainStatus(migration))
                    .foregroundStyle(attention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            } label: { Label(String(localized: "Your macOS Keychain", bundle: .module), systemImage: "xmark.shield") }
            Toggle(isOn: settings.mulgChainDebugging) {
                Label {
                    OptionLabel(String(localized: "Keychain debugging", bundle: .module), .restart, key: "mulgChainDebugging", owner: .integrations)
                } icon: { Image(systemName: "ladybug") }
            }
            .disabled(!saves)
        } header: {
            Text("Logins & protection", bundle: .module)
        } footer: {
            Text("The game reaches only its own files. It never sees your macOS Keychain, other apps' data or other games' files: macOS enforces this, whatever the game's code does. Turning saving off keeps logins only until the game quits.", bundle: .module)
        }
    }

    static func keychainStatus(_ migration: GameSandboxAccess.MigrationState) -> String {
        switch migration {
        case .none: String(localized: "Walled off", bundle: .module)
        case .notStarted, .pending: String(localized: "Old logins move out on the next launch, then walled off", bundle: .module)
        case .stuck: String(localized: "Walled off. Old logins could not be moved: Clear saved logins to start fresh", bundle: .module)
        case .waitingForUnlock: String(localized: "Walled off. Old logins move out after you unlock the Mulg vault", bundle: .module)
        }
    }

    private func toggle(_ title: String, _ symbol: String, _ value: Binding<Bool>, key: String) -> some View {
        Toggle(isOn: value) {
            Label {
                OptionLabel(title, .live, key: key, owner: .engine)
            } icon: { Image(systemName: symbol) }
        }
    }
}
#endif
