#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import MulgContracts
import SwiftUI

/// A dedicated per-game page. Its settings use the same locked delta writer and runtime
/// acknowledgements as the other pages; enabling one game never enables another.
public struct GameBypassesTab: View {
    private let bundleIdentifier: String
    private let saved: () -> Void
    @Environment(\.gameSettingsPresentation) private var presentation
    @State private var warnings: [OnlineWarning.Feature] = []
    @State private var report: EnvironmentBypassReport?
    @State private var startupStatus: RuntimeModuleStatusReport?

    public init(bundleIdentifier: String, saved: @escaping () -> Void) {
        self.bundleIdentifier = bundleIdentifier
        self.saved = saved
    }

    public var body: some View {
        GameSettingsFile(bundleIdentifier: bundleIdentifier, saved: saved) { settings in
            Form {
                Section {
                    Picker(selection: settings.iosDeviceModel) {
                        ForEach(MobileDeviceCatalog.all) { profile in
                            Text(profile.configured(settings.wrappedValue.mulg.identity.deviceConfiguration).pickerLabel)
                                .tag(profile.id)
                        }
                        if MobileDeviceCatalog.profile(for: settings.wrappedValue.iosDeviceModel) == nil {
                            Text("Custom: \(settings.wrappedValue.iosDeviceModel)")
                                .tag(settings.wrappedValue.iosDeviceModel)
                        }
                    } label: { GameSettingLabel("Reported device", key: "iosDeviceModel", owner: .identity) }
                    if let profile = MobileDeviceCatalog.profile(for: settings.wrappedValue.iosDeviceModel,
                        configuration: settings.wrappedValue.mulg.identity.deviceConfiguration) {
                        if profile.supportsConfigurations {
                            Picker(selection: settings.mulg.identity.deviceConfiguration) {
                                Text("256 / 512 GB · \(profile.configured(.standard).memoryLabel) · 9 CPU cores")
                                    .tag(MobileDeviceConfiguration.standard)
                                Text("1 / 2 TB · 16GB · 10 CPU cores")
                                    .tag(MobileDeviceConfiguration.highCapacity)
                            } label: {
                                GameSettingLabel("Device configuration", key: "mulg.identity.deviceConfiguration",
                                    owner: .identity, modularOnly: true)
                            }
                        } else if settings.wrappedValue.mulg.identity.deviceConfiguration != .standard {
                            Text("This device uses its standard CPU/RAM profile. The high-capacity preference is retained for supported iPads.")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Use standard configuration") {
                                settings.mulg.identity.deviceConfiguration.wrappedValue = .standard
                            }
                        }
                        LabeledContent("Board / chip", value: "\(profile.boardID) · \(profile.chip)")
                        LabeledContent("RAM / display", value: "\(profile.memoryLabel) · \(profile.maximumRefreshRate) Hz")
                        if let cpu = profile.cpu {
                            LabeledContent("Profile CPU", value: "\(cpu.totalCores) cores · \(cpu.performanceCores) fast + \(cpu.efficiencyCores) efficiency")
                        }
                        if !profile.inconsistencies.isEmpty {
                            Text("This profile has incomplete hardware data. Use the recommended iPad for the fullest identity coverage.")
                                .font(.callout).foregroundStyle(.orange)
                        }
                    }
                    if settings.wrappedValue.iosDeviceModel != MobileDeviceCatalog.recommendedDefault {
                        Button("Use recommended M5 iPad") {
                            settings.iosDeviceModel.wrappedValue = MobileDeviceCatalog.recommendedDefault
                            settings.mulg.identity.deviceConfiguration.wrappedValue = .standard
                        }
                    }
                } header: { Text("Device profile") }
                  footer: { Text("Uses the same profile as Device & fixes. Takes effect at the next game launch; render resolution and controls remain independent.") }

                if startupStatus?.identityDisabledByRecovery == true {
                    Section("Recovery") {
                        Label("Identity compatibility was disabled for this launch after repeated failed starts.", systemImage: "exclamationmark.triangle")
                        Toggle(isOn: settings.mulg.engine.automaticRecovery) {
                            GameSettingLabel("Automatic recovery", key: "mulg.engine.automaticRecovery", owner: .engine)
                        }
                        Text("Recovery changes apply when the game is launched again.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Toggle(isOn: settings.mulg.identity.matchMobileInterface) {
                        GameSettingLabel("Match mobile interface", key: "mulg.identity.matchMobileInterface", owner: .identity)
                    }
                    Toggle(isOn: compatibilityToggle(settings.mulg.identity.environmentBypass)) {
                        GameSettingLabel("Consistent mobile identity", key: "mulg.identity.environmentBypass", owner: .identity)
                    }
                    Text("Matches the selected device's model, board, CPU, memory limit and mobile interface for game callers. Apple frameworks retain native Mac answers. Includes known SDK checks; ordinary preferences return when turned off.")
                        .font(.callout).foregroundStyle(.secondary)
                } header: { Text("Environment") }
                  footer: { Text("Off by default. Takes effect at the next game launch. Game-specific integrity restrictions may still prevent play.") }

                Section {
                    Toggle(isOn: compatibilityToggle(settings.bypass)) {
                        GameSettingLabel("Legacy jailbreak compatibility", key: "bypass", owner: .identity)
                    }
                    Text("Known SDK jailbreak checks and path-specific sandbox compatibility rules. Consistent mobile identity already enables the SDK checks; this adds the legacy rules.")
                        .font(.callout).foregroundStyle(.secondary)
                } header: { Text("Legacy compatibility") }
                  footer: { Text("Off for new games. Changes the game's signing permissions at its next launch.") }

                Section {
                    if let report = sessionReport {
                        LabeledContent("Session", value: presentation.running ? "Current launch" : "Last launch")
                        LabeledContent("Started", value: report.launchStartedAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Environment mode", value: report.enabled ? "Enabled at launch" : "Off at launch")
                        LabeledContent("Reported device", value: report.deviceIdentifier)
                        if report.enabled, report.identityAudit == nil, let count = report.mobileUIHooksInstalled {
                            LabeledContent("Mobile interface hooks", value: "\(count) of 2")
                        }
                        if !report.deviceRecognized {
                            Label("The selected device is not in Mulg's catalog. Choose a supported device above.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        if report.knownSDKChecksRequested {
                            LabeledContent("Supported SDK checks found", value: "\(report.installedSDKChecks) of \(report.availableSDKChecks)")
                            if report.installedSDKChecks == 0 {
                                Text("No matching SDK checks have been found. This game may use a different protection system.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        } else {
                            LabeledContent("Known SDK checks", value: "Off at launch")
                        }
                    } else {
                        Text(presentation.running ? "Waiting for this game's runtime report." : "Launch the game to see which supported checks are present.")
                            .foregroundStyle(.secondary)
                    }
                } header: { Text("Runtime status") }
                  footer: { Text("Reports the active configuration and matched hooks. It does not confirm that the game's protection accepted the environment.") }
                if let audit = sessionReport?.identityAudit {
                    IdentityCoverageSection(audit: audit)
                }
                Section("Game integrity") {
                    Text("Device identity is separate from app integrity. A converted, re-signed game remains a wrapped app. Game-specific signing or device-attestation requirements may prevent play even when every identity hook is active.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .onlineWarnings($warnings)
        .task(id: bundleIdentifier) {
            while !Task.isCancelled {
                loadReport()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
    }

    private var sessionReport: EnvironmentBypassReport? {
        guard let report, report.bundleIdentifier == bundleIdentifier else { return nil }
        if presentation.running {
            guard let startupStatus,
                  startupStatus.matches(processIdentifier: report.processIdentifier, launchSessionID: report.launchSessionID),
                  startupStatus.identityState == nil || startupStatus.identityPrepared else { return nil }
            guard report.processIdentifier == presentation.runtime?.processIdentifier,
                  let application = NSRunningApplication(processIdentifier: report.processIdentifier),
                  application.bundleIdentifier == bundleIdentifier, !application.isTerminated,
                  report.belongsToLaunch(bundleIdentifier: bundleIdentifier,
                      processIdentifier: application.processIdentifier,
                      processLaunchDate: application.launchDate) else { return nil }
        } else if let application = NSRunningApplication(processIdentifier: report.processIdentifier),
                  application.bundleIdentifier == bundleIdentifier, !application.isTerminated,
                  report.belongsToLaunch(bundleIdentifier: bundleIdentifier,
                      processIdentifier: application.processIdentifier, processLaunchDate: application.launchDate) {
            return nil // An unaccepted/pending process is not the last completed launch.
        }
        return report
    }

    private func loadReport() {
        let file = SettingsStore().paths.diagnosticsDirectory(for: bundleIdentifier)
            .appendingPathComponent("environment-bypass.json")
        let startupFile = file.deletingLastPathComponent().appendingPathComponent("startup.json")
        startupStatus = (try? Data(contentsOf: startupFile)).flatMap {
            try? JSONDecoder().decode(RuntimeModuleStatusReport.self, from: $0)
        }
        report = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(EnvironmentBypassReport.self, from: $0) }
    }

    private func compatibilityToggle(_ setting: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { setting.wrappedValue }, set: { enabled in
            let wasEnabled = setting.wrappedValue
            setting.wrappedValue = enabled
            if enabled && !wasEnabled && setting.wrappedValue {
                warnings += OnlineWarning.pending([.compatibilityBypass], bundleIdentifier: bundleIdentifier)
            }
        })
    }
}
private struct IdentityCoverageSection: View {
    let audit: DeviceIdentityAudit

    var body: some View {
        Section {
            LabeledContent("Launched profile", value: audit.profileName)
            LabeledContent("Board / platform", value: "\(audit.boardIdentifier) · \(audit.hardwarePlatform)")
            if let cores = audit.cpuCores {
                LabeledContent("Configured CPU cores", value: String(cores))
            }
            LabeledContent("RAM budget", value: ByteCountFormatter.string(
                fromByteCount: Int64(clamping: audit.reportedMemoryBytes), countStyle: .memory))
            LabeledContent("Configuration", value: audit.configured ? "Configured" : "Unavailable")
            LabeledContent("Scope", value: audit.gameOnlyAnswers ? "Game callers only" : "Legacy")
            if let signals = audit.signals {
                LabeledContent("Configured signals") {
                    Text("\(signals.filter(\.matches).count) of \(signals.count) agree")
                        .foregroundStyle(audit.hasMismatchedSignals ? Color.orange : Color.secondary)
                }
                ForEach(signals.filter { !$0.matches }) { signal in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(signal.title).font(.callout.weight(.medium))
                        Text("Expected \(signal.expected); configured \(signal.configured ?? "unavailable")")
                            .font(.caption)
                    }.foregroundStyle(.orange)
                }
            }
            ForEach(audit.hooks) { hook in
                LabeledContent(hook.title) {
                    Text("\(hook.installed) of \(hook.expected)")
                        .foregroundStyle(hook.complete ? Color.secondary : Color.orange)
                }
            }
            ForEach(Array(audit.warnings.enumerated()), id: \.offset) { _, warning in
                Text(warning).font(.callout).foregroundStyle(.orange)
            }
            if !audit.boardVerified {
                Text("The catalog's board identity has not been verified on a physical device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text("Identity coverage") }
          footer: { Text("Installed getters and profile-table comparisons for this launch. Missing hooks or mismatches can reduce compatibility. GPU capabilities and OS API availability stay native.") }
    }
}
#endif
