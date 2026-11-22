#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import MulgContracts
import MulgLibrary
import SwiftUI

/// General login support belongs beside per-game credential storage, not device spoofing.
public struct GameLoginSupportSection: View {
    @Environment(\.gameSettingsPresentation) private var presentation
    private let gameURL: URL
    private let bundleIdentifier: String
    @State private var report: LoginCompatibilityReport?
    @State private var removedAppleCapability = false
    @State private var callbackCount = 0
    @State private var registrationError: String?
    @State private var registering = false
    @State private var compatibility = true
    @State private var settingProblem: String?

    public init(gameURL: URL, bundleIdentifier: String) {
        self.gameURL = gameURL
        self.bundleIdentifier = bundleIdentifier
    }

    public var body: some View {
        Section("Sign-in") {
            Toggle(isOn: Binding(get: { compatibility }, set: saveCompatibility)) {
                GameSettingLabel("Login compatibility", key: "mulg.integrations.authenticationCompatibility", owner: .integrations)
            }.disabled(settingProblem != nil || !presentation.modular)
            LabeledContent("Browser callbacks", value: callbackCount == 0 ? "No custom schemes declared" : "\(callbackCount) declared")
            Text("Browser sign-in uses the game's original provider and callback. Presentation repair runs with the Integrations module.")
                .font(.caption).foregroundStyle(.secondary)
            if presentation.settings?.mulgChain == true {
                Text("Protected login tokens use this Mac's Secure Enclave and stay on this Mac. Login storage is controlled separately above.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if removedAppleCapability {
                LabeledContent("Native Apple sign-in", value: "Publisher provisioning unavailable")
                Text("This converted app lost its publisher's Apple sign-in entitlement. Mulg cannot grant it. Web sign-in can work when the game provides that option.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Apple sign-in also requires valid publisher provisioning; its absence from this report does not confirm support.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let report, report.bundleIdentifier == bundleIdentifier {
                let current = presentation.runtime.map {
                    $0.processIdentifier == report.processIdentifier && $0.launchSessionID == report.launchSessionID
                } ?? false
                if current {
                    LabeledContent("Launched support", value: !report.enabled ? "Disabled" : report.installedHooks.isEmpty ? "Unavailable" : "Active")
                }
                if let event = report.events.last {
                    LabeledContent(current ? "Latest sign-in" : "Previous sign-in", value: "\(providerLabel(event.provider)): \(stateLabel(event.state))")
                    if let domain = event.errorDomain, let code = event.errorCode {
                        Text("\(domain) (\(code))").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text(event.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Button(registering ? "Registering…" : "Repair browser callback registration") {
                registering = true
                registrationError = nil
                let url = gameURL, identifier = bundleIdentifier
                Task {
                    do {
                        _ = try await Task.detached(priority: .utility) {
                            try GameApplicationRegistration.register(url, bundleIdentifier: identifier)
                        }.value
                    } catch { registrationError = error.localizedDescription }
                    registering = false
                }
            }.disabled(registering || callbackCount == 0)
            if let registrationError { Text(registrationError).font(.caption).foregroundStyle(.red) }
            if let settingProblem { Text(settingProblem).font(.caption).foregroundStyle(.red) }
        }
        .onChange(of: presentation.settings?.mulg.integrations.authenticationCompatibility) { _, value in
            if let value { compatibility = value }
        }
        .task {
            let settings = SettingsStore().load(bundleIdentifier: bundleIdentifier)
            compatibility = settings.settings.mulg.integrations.authenticationCompatibility
            settingProblem = settings.problem?.localizedDescription
            let url = gameURL
            let metadata = await Task.detached(priority: .utility) {
                let unavailable = (try? Data(contentsOf: url.appendingPathComponent("MulgCapabilities.json")))
                    .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
                let data = try? Data(contentsOf: url.appendingPathComponent("Info.plist"))
                let info = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
                let entries = info?["CFBundleURLTypes"] as? [[String: Any]] ?? []
                return (unavailable.contains { $0.hasSuffix(": com.apple.developer.applesignin") },
                        Set(entries.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }).count)
            }.value
            removedAppleCapability = metadata.0
            callbackCount = metadata.1
            let file = SettingsStore().paths.diagnosticsDirectory(for: bundleIdentifier).appendingPathComponent("authentication.json")
            while !Task.isCancelled {
                let latest = await Task.detached(priority: .utility) {
                    (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(LoginCompatibilityReport.self, from: $0) }
                }.value
                if !Task.isCancelled { report = latest }
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
    }

    private func saveCompatibility(_ enabled: Bool) {
        let store = SettingsStore()
        let loaded = store.load(bundleIdentifier: bundleIdentifier)
        guard loaded.problem == nil else { settingProblem = loaded.problem?.localizedDescription; return }
        var edited = loaded.settings
        edited.mulg.integrations.authenticationCompatibility = enabled
        do {
            _ = try store.save(edited, basedOn: loaded.settings)
            compatibility = enabled
            settingProblem = nil
        } catch { settingProblem = error.localizedDescription }
    }

    private func providerLabel(_ value: String) -> String { value == "apple" ? "Apple" : value == "web" ? "Browser" : "Native" }
    private func stateLabel(_ value: String) -> String {
        switch value {
        case "requested": "Started"
        case "completed": "Provider completed"
        case "cancelled": "Cancelled"
        case "failed": "Failed"
        case "startRejected": "Could not start"
        case "presentationFailed": "Window presentation failed"
        default: "Unconfirmed"
        }
    }
}
#endif
