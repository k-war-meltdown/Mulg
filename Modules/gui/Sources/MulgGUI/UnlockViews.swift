// Host-side module: the Mulg app is a native macOS app, never Mac Catalyst.
#if os(macOS) && !targetEnvironment(macCatalyst)
import MulgContracts
import SwiftUI

/// The Game unlocks page: everything that lifts a limit the game sets itself. The frame-rate
/// unlock (display, graphics) and camera reach (camera) in one place.
public struct GameUnlocksTab: View {
    let bundleIdentifier: String
    let saved: () -> Void
    @State private var warnings: [OnlineWarning.Feature] = []

    public init(bundleIdentifier: String, saved: @escaping () -> Void) {
        self.bundleIdentifier = bundleIdentifier
        self.saved = saved
    }

    public var body: some View {
        GameSettingsFile(bundleIdentifier: bundleIdentifier, saved: saved) { settings in
            Form {
                FrameRateUnlockSection(display: settings.mulg.display,
                                       followsDisplay: ResolutionMode(setting: settings.wrappedValue.resolution) == .display)
                CameraReachSection(settings: settings.mulg.camera, bundleIdentifier: bundleIdentifier, warnings: $warnings)
            }
            .formStyle(.grouped)
            .onlineWarnings($warnings)
        }
    }
}

/// Unlock 120 FPS: raises the game's own frame cap to the display's refresh rate.
struct FrameRateUnlockSection: View {
    @Binding var display: DisplaySettings
    /// The "This display" resolution already unlocks to the monitor's refresh rate.
    let followsDisplay: Bool

    private var refreshRate: Int { NSScreen.main?.maximumFramesPerSecond ?? 60 }

    var body: some View {
        Section {
            Toggle(isOn: $display.uncapFrameRate) {
                OptionLabel("Unlock high frame rate", .live, key: "mulg.display.uncapFrameRate", owner: .display)
            }
            .disabled(followsDisplay)
            Toggle(isOn: $display.reportProMotion) {
                OptionLabel("Report 120 Hz screen", .restart, key: "mulg.display.reportProMotion", owner: .display)
            }
            .disabled(followsDisplay)
            if followsDisplay {
                Text("The This display resolution already runs at your display's own refresh rate.", bundle: .module)
                    .font(.caption).foregroundStyle(.secondary)
            } else if refreshRate <= 60 {
                Text("This display shows at most 60 Hz, so there is nothing above 60 FPS to unlock on it.", bundle: .module)
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Frame rate", bundle: .module)
        } footer: {
            Text("For games whose own settings stop at 60 FPS. Up to \(refreshRate) FPS on this display: the game's display link, Unity's frame-rate setting (games that keep Unity's interfaces, such as Ragnarok) and 1/60 s present pacing are raised. A frame-rate cap under Graphics still applies. Games tied to 60 FPS may run too fast; switch it off then.", bundle: .module)
        }
    }
}
#endif
