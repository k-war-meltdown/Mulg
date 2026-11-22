#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import MulgContracts
import SwiftUI

/// Configuration badges describe saved settings; this section separately reports real output.
struct GameAudioOutputSection: View {
    @Binding var settings: AudioOutputSettings
    let bundleIdentifier: String
    var supportedRuntime = true
    @State private var report: AudioOutputReport?
    @State private var running = false

    var body: some View {
        Section {
            // Fixed: games always get the iPad's native rate; the device is switched while they run.
            LabeledContent("Output sample rate", value: "\(rate(AudioOutputSettings.iPadSampleRate)) (iPad native)")
            Picker(selection: $settings.depth) {
                ForEach(AudioOutputSettings.Depth.allCases, id: \.self) { depth in
                    Text(depth.title).tag(depth)
                }
            } label: {
                GameSettingLabel("Output bit depth", key: "mulg.engine.audioOutput.depth", owner: .engine, modularOnly: true)
            }
            Toggle(isOn: $settings.restoreOnExit) {
                GameSettingLabel("Restore format on exit", key: "mulg.engine.audioOutput.restoreOnExit", owner: .engine, modularOnly: true)
            }
            if !supportedRuntime {
                Label("Device-format protection requires the modular runtime.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let report {
                LabeledContent("Output device", value: report.deviceName)
                LabeledContent("Actual output", value: hardwareFormat(report))
                LabeledContent("Game audio session", value: report.sessionSampleRate > 0 ? rate(report.sessionSampleRate) : "Not active yet")
                HStack(alignment: .top) {
                    Label(statusTitle(report.state), systemImage: statusSymbol(report.state))
                        .font(.caption).foregroundStyle(statusColor(report.state)).fixedSize()
                    Text(report.message).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if report.sessionSampleRate > 0 && report.sampleRate > 0,
                   abs(report.sessionSampleRate - report.sampleRate) >= 0.5 {
                    Text("The game session and device use different rates. macOS handles output conversion.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !report.availableSampleRates.isEmpty || !report.availableBitDepths.isEmpty {
                    DisclosureGroup("Device formats") {
                        if !report.availableSampleRates.isEmpty {
                            LabeledContent("Sample rates", value: report.availableSampleRates.map(rate).joined(separator: ", "))
                        }
                        if !report.availableBitDepths.isEmpty {
                            LabeledContent("Bit depths at selected rate", value: report.availableBitDepths.map { "\($0)-bit" }.joined(separator: ", "))
                        }
                        Text("Actual output last checked \(report.updated.formatted(date: .omitted, time: .standard)).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(running ? "Waiting for this game's audio report. Older runtimes need to be refreshed before this feature is available."
                     : "The device's actual format will appear after the next game launch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Audio")
        } footer: {
            Text("Keeps Audio MIDI Setup's format by default. Changes require a game restart. Device format affects other apps using that output; higher rates do not add detail to lower-rate game audio.")
        }
        .disabled(!supportedRuntime)
        .task(id: bundleIdentifier) {
            guard supportedRuntime else { return }
            while !Task.isCancelled {
                readReport()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func readReport() {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).filter { !$0.isTerminated }
        running = !apps.isEmpty
        let file = ContainerPaths.current().diagnosticsDirectory(for: bundleIdentifier).appendingPathComponent("audio-output.json")
        guard running, let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65_536,
              let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(AudioOutputReport.self, from: data),
              apps.contains(where: { $0.processIdentifier == value.processIdentifier && ($0.launchDate.map { value.updated >= $0 } ?? true) }) else {
            report = nil; return
        }
        report = value
    }

    private func rate(_ value: Double) -> String {
        guard value.isFinite && value > 0 else { return "Unavailable" }
        return String(format: "%.1f kHz", value / 1000)
    }
    private func hardwareFormat(_ value: AudioOutputReport) -> String {
        let depth = value.bitDepth > 0 ? "\(value.bitDepth)-bit \(value.floatingPoint ? "float" : "PCM")" : "bit depth unavailable"
        return "\(rate(value.sampleRate)) · \(depth)"
    }
    private func statusTitle(_ value: String) -> String {
        switch value {
        case "applied": "Verified"
        case "unsupported": "Unsupported"
        case "unavailable": "Unavailable"
        case "conflict": "Format conflict"
        case "recovery": "Disabled by recovery"
        case "disabled": "Game managed"
        default: "Applying…"
        }
    }
    private func statusSymbol(_ value: String) -> String {
        switch value {
        case "applied": "checkmark.circle"
        case "unsupported", "unavailable", "conflict": "exclamationmark.triangle"
        case "recovery", "disabled": "minus.circle"
        default: "clock"
        }
    }
    private func statusColor(_ value: String) -> Color {
        ["unsupported", "unavailable", "conflict", "recovery"].contains(value) ? .orange : .secondary
    }
}
#endif
