// Host-side module: the Mulg app is a native macOS app, never Mac Catalyst.
#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import MulgContracts
import SwiftUI

public enum DefaultProfile {
    public static var saved: PerformanceProfile? {
        UserDefaults.standard.string(forKey: GUIKey.defaultProfile).flatMap(PerformanceProfile.init(rawValue:))
    }

    public static func applyToNewGame(_ bundleIdentifier: String) throws {
        let actions = GameActions()
        try actions.disableDebugging(for: bundleIdentifier)
        try actions.applyPrivacyDefaults(for: bundleIdentifier)
        try actions.applyBackgroundPlayDefaults(for: bundleIdentifier)
        try actions.applyPerformanceDefaults(for: bundleIdentifier)
        guard let profile = saved else { return }
        _ = try actions.applyProfile(profile, to: bundleIdentifier)
        if profile == .fps120 {
            _ = OnlineWarning.pending([.deviceIdentity], bundleIdentifier: bundleIdentifier)
        }
    }
}

extension PerformanceProfile {
    var symbol: String {
        switch self {
        case .fps120: "bolt.fill"
        case .balanced: "dial.medium.fill"
        case .batterySaver: "leaf.fill"
        }
    }
    var summary: String {
        switch self {
        case .fps120: String(localized: "Reports an iPad Pro (M5) with a 120 Hz screen and lifts the frame cap.", bundle: .module)
        case .balanced: String(localized: "Uncapped, just below the refresh rate, at 1440p.", bundle: .module)
        case .batterySaver: String(localized: "A capped frame rate at 1080p, for long sessions on battery.", bundle: .module)
        }
    }
}

public struct OnboardingView: View {
    private enum Step: Int, CaseIterable { case welcome, mac, look, games, signIn, playing, profile, done }
    @State private var step = Step.welcome
    @State private var checks: [MacCheck] = []
    @AppStorage(GUIKey.appearance) private var appearance = MulgAppearance.system
    @AppStorage(GUIKey.translucentWindow) private var translucent = true
    @AppStorage(GUIKey.defaultProfile) private var defaultProfile = ""
    @AppStorage(GUIKey.onboardingDone) private var onboardingDone = false
    @Environment(\.dismiss) private var dismiss
    private let onAddGame: () -> Void

    public init(onAddGame: @escaping () -> Void = {}) { self.onAddGame = onAddGame }

    public var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .mac: macPage
                case .look: lookPage
                case .games: gamesPage
                case .signIn: signInPage
                case .playing: playingPage
                case .profile: profilePage
                case .done: donePage
                }
            }
            .id(step)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 44).padding(.top, 36)
            footer
        }
        .frame(width: 700, height: 580)
        .background(EmberGlow()).mulgAppearance()
        .onChange(of: appearance) { appearance.apply() }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Text("Welcome to Mulg").font(.largeTitle.weight(.semibold))
            Text("Your iPad games, tuned for this Mac.", bundle: .module).font(.title3).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                feature("square.grid.2x2.fill", "Library", "Every game in one place, one click from playing.")
                feature("gauge.with.dots.needle.67percent", "Performance", "Profiles up to 120 FPS on ProMotion displays.")
                feature("gamecontroller.fill", "Controls", "Keyboard, mouse and controller mapping.")
            }.padding(.top, 10)
        }
    }

    private var macPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Your Mac", "Check the display, chip, power and memory before playing.")
            ForEach(checks) { check in
                HStack(alignment: .top) {
                    Image(systemName: check.state.symbol).foregroundStyle(check.state.color)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(check.title).font(.headline)
                        Text(check.detail).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Button("Check again") { checks = MacCheck.run(.current()) }
        }.onAppear { checks = MacCheck.run(.current()) }
    }

    private var lookPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            header("Make it yours", "Choose how Mulg looks.")
            HStack(spacing: 18) {
                ForEach(MulgAppearance.allCases) { option in
                    Button { appearance = option } label: {
                        VStack(spacing: 8) {
                            AppearanceSwatch(appearance: option, selected: appearance == option)
                            Text(option.title)
                        }
                    }.buttonStyle(.plain)
                }
            }
            Toggle("Translucent windows", isOn: $translucent)
            Text("Reduce transparency in Accessibility turns it off everywhere.").foregroundStyle(.secondary)
        }
    }

    private var gamesPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            header("Your games", "Install an IPA, then choose its settings in the Library.")
            row("plus.app", "Add a game", "Drop a decrypted IPA onto the Library, or use Add Game.")
            row("externaldrive", "Files and privacy", "Downloaded data and saved logins belong to each game. Permissions start denied and can be enabled per game.")
            row("slider.horizontal.3", "Settings for each game", "Adjust resolution, performance, controls and compatibility from the game's settings.")
        }
    }

    private var signInPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            header("Signing in to games", "A quick note before you start playing.")
            row("person.crop.circle", "Use Google or email", "Choose Google or email on the game's sign-in screen. Sign in with Apple doesn't work in Mulg.")
            row("link", "Already using Apple?", "Before playing here, open the game on your iPhone or iPad and link Google or email to the same game account, if the game supports it.")
        }
    }

    private var playingPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            header("Keyboard and mouse", "Touchscreen mapping translates your inputs into the game's controls.")
            row("keyboard", "Edit controls with ⌘K", "Use the Controls menu while the game is open to edit, import or switch keymaps.")
            row("cursorarrow", "Tap ⌥ Option or click the mouse wheel", "Shows the cursor for menus and keeps it. Tap or click again to go back to the camera.")
            row("lock", "The mouse stays in the game", "While you play, windowed or full screen, the cursor, clicks and keybinds can't leave the game window. To leave, hold ⌘ Command and press Q to quit the game, as in any Mac app.")
            row("gamecontroller", "Choose the game's play mode", "Use touchscreen mapping or a virtual controller according to the game's controls.")
        }
    }

    private var profilePage: some View {
        VStack(alignment: .leading, spacing: 12) {
            header("A starting profile", "New games use this profile. Existing games keep their settings.")
            ProfileChoice(symbol: "ipad", title: "As installed", summary: "Keep the normal install defaults.", selected: defaultProfile.isEmpty) { defaultProfile = "" }
            ForEach(PerformanceProfile.allCases) { profile in
                ProfileChoice(symbol: profile.symbol, title: profile.title, summary: profile.summary,
                              selected: defaultProfile == profile.rawValue) { defaultProfile = profile.rawValue }
            }
            if defaultProfile == PerformanceProfile.fps120.rawValue {
                Label(OnlineWarning.message(for: .deviceIdentity), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var donePage: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle").font(.system(size: 60, weight: .light)).foregroundStyle(.green)
            Text("You're all set", bundle: .module).font(.largeTitle.bold())
            Text("Drop a decrypted .ipa onto the Library, or pick one from a source.", bundle: .module)
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Add a game now…") { finish(); onAddGame() }.buttonStyle(.glass).controlSize(.large)
        }
    }

    private var footer: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { page in
                    Capsule().fill(page == step ? AnyShapeStyle(MulgStyle.accent) : AnyShapeStyle(.quaternary))
                        .frame(width: page == step ? 18 : 6, height: 6)
                }
            }
            HStack {
                if step == .welcome { Button("Skip", action: finish).buttonStyle(.borderless) }
                else { Button("Back") { move(-1) }.buttonStyle(.glass) }
                Spacer()
                Button(step == .done ? "Start Playing" : "Continue") {
                    if step == .done { finish() } else { move(1) }
                }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
        }.controlSize(.large).padding(20)
    }

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.largeTitle.bold())
            Text(subtitle).foregroundStyle(.secondary)
        }.padding(.bottom, 6)
    }
    private func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.title2).foregroundStyle(MulgStyle.accent)
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).mulgCard(radius: 16)
    }
    private func row(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(MulgStyle.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
    private func move(_ delta: Int) { withAnimation(.snappy) { step = Step(rawValue: step.rawValue + delta) ?? step } }
    private func finish() { onboardingDone = true; dismiss() }
}

struct AppearanceSwatch: View {
    let appearance: MulgAppearance
    let selected: Bool
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(spacing: 0) {
            if appearance != .dark { window(dark: false) }
            if appearance != .light { window(dark: true) }
        }.frame(width: 150, height: 96).clipShape(shape)
            .overlay(shape.strokeBorder(selected ? MulgStyle.accent : Color(nsColor: .separatorColor), lineWidth: selected ? 3 : 1))
    }
    private func window(dark: Bool) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(dark ? Color(white: 0.16) : Color(white: 0.9)).frame(width: 30)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(dark ? Color(white: 0.1) : .white)
                RoundedRectangle(cornerRadius: 4).fill(MulgStyle.ember).frame(width: 34, height: 20).padding(10)
            }
        }
    }
}

struct ProfileChoice: View {
    let symbol: String
    let title: String
    let summary: String
    let selected: Bool
    let choose: () -> Void
    var body: some View {
        Button(action: choose) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.title3).foregroundStyle(MulgStyle.accent).frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(MulgStyle.accent) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12).mulgCard()
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
#endif
