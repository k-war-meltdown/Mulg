// Host-side module: the Mulg app is a native macOS app, never Mac Catalyst.
#if os(macOS) && !targetEnvironment(macCatalyst)
import SwiftUI

/// Settings > General: look, the profile new games get, and the welcome assistant.
public struct GeneralSettings: View {
    @AppStorage(GUIKey.appearance) private var appearance = MulgAppearance.system
    @AppStorage(GUIKey.translucentWindow) private var translucent = true
    @AppStorage(GUIKey.defaultProfile) private var defaultProfile = ""
    @AppStorage(GameMenuBarController.preferenceKey) private var hideOnLaunch = true
    @AppStorage(GUIKey.onboardingDone) private var onboardingDone = false

    public init() {}

    public var body: some View {
        Form {
            Section(String(localized: "Appearance", bundle: .module)) {
                // The pictures when they fit; a plain picker in a narrow window.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        ForEach(MulgAppearance.allCases) { option in
                            Button { appearance = option } label: {
                                VStack(spacing: 6) {
                                    AppearanceSwatch(appearance: option, selected: appearance == option)
                                        .scaleEffect(0.8)
                                        .frame(width: 120, height: 78)
                                    Text(option.title).font(.callout)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    Picker(String(localized: "Appearance", bundle: .module), selection: $appearance) {
                        ForEach(MulgAppearance.allCases) { Text($0.title).tag($0) }
                    }
                }
                Toggle(String(localized: "Translucent windows", bundle: .module), isOn: $translucent)
            }
            Section {
                Picker(String(localized: "Profile for new games", bundle: .module), selection: $defaultProfile) {
                    Text(String(localized: "As installed", bundle: .module)).tag("")
                    ForEach(PerformanceProfile.allCases) { profile in
                        Text(profile.title).tag(profile.rawValue)
                    }
                }
            } footer: {
                if let profile = PerformanceProfile(rawValue: defaultProfile) {
                    Text(profile.summary).foregroundStyle(.secondary)
                } else {
                    Text("New games use full desktop resolution and a 120 FPS target, with automatic power saving and downscaling off.")
                        .foregroundStyle(.secondary)
                }
                // New games skip the in-game warning for this default (DefaultProfile), so it is
                // shown here, as on the welcome assistant.
                if defaultProfile == PerformanceProfile.fps120.rawValue {
                    Label(OnlineWarning.message(for: .deviceIdentity), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Section("While playing") {
                Toggle("Hide Mulg in the menu bar", isOn: $hideOnLaunch)
                Text("The library returns when the last game closes. Use Mulg's menu-bar icon to reopen it while playing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button(String(localized: "Show Welcome Again", bundle: .module)) { onboardingDone = false }
            }
        }
        .formStyle(.grouped)
        .mulgAppearance()
        .onChange(of: appearance) { appearance.apply() }
        .frame(minWidth: 380, idealWidth: 520)
    }
}

/// Settings > About: the logo, the version and where the code comes from.
public struct AboutSettings: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 12) {
            Text("Mulg").font(.largeTitle.weight(.semibold))
            Text(verbatim: Self.version)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(String(localized: "Your iPad games, tuned for this Mac.", bundle: .module))
            Text(String(localized: "Mulg includes open-source code under the GPL-3.0 and AGPL-3.0 licences. CREDITS.md in the source lists every project and its licence.", bundle: .module))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.top, 6)
        }
        .padding(30)
        .frame(minWidth: 380, idealWidth: 520)
        .background(EmberGlow())
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
#endif
