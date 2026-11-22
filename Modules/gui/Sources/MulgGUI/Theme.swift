// Host-side module: the Mulg app is native macOS, never Mac Catalyst.
#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import SwiftUI

public enum GUIKey {
    public static let appearance = "gui.appearance"
    public static let translucentWindow = "gui.translucentWindow"
    public static let defaultProfile = "gui.defaultProfile"
    /// ".v2": the guide gained the Your games and Playing pages (2026-10-10), so everyone sees it once more.
    public static let onboardingDone = "gui.onboardingDone.v2"
    public static let askInstallFolder = "gui.askInstallFolder"
    public static let installFolder = "gui.installFolder"
    public static func lastPlayed(_ bundleIdentifier: String) -> String { "library.lastPlayed.\(bundleIdentifier)" }
}

/// The saved preference reaches SwiftUI roots and AppKit windows, menus and alerts.
public enum MulgAppearance: String, Sendable, CaseIterable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .system: String(localized: "Automatic", bundle: .module)
        case .light: String(localized: "Light", bundle: .module)
        case .dark: String(localized: "Dark", bundle: .module)
        }
    }
    public var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
    public static var saved: MulgAppearance {
        UserDefaults.standard.string(forKey: GUIKey.appearance).flatMap(Self.init(rawValue:)) ?? .system
    }
    /// The one place the choice is applied: the app's appearance, which every window, sheet, menu and
    /// alert inherits, and SwiftUI follows through each window's effective appearance. Windows lose any
    /// appearance of their own: SwiftUI's preferredColorScheme pinned one and never cleared it, so going
    /// back to Automatic left windows in the old mode until a relaunch (2026-10-10 fix).
    @MainActor public func apply() {
        let wanted: NSAppearance? = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        NSApp.appearance = wanted
        for window in NSApp.windows where window.appearance != nil {
            window.appearance = nil
        }
    }
}

/// Quiet neutral surfaces, semantic text and a single restrained vermilion accent.
public enum MulgStyle {
    private static func adaptive(_ name: String, light: (CGFloat, CGFloat, CGFloat),
                                 dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name("io.mulg.gui.\(name)")) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: 1)
        })
    }
    public static let canvas = adaptive("canvas", light: (0.96, 0.95, 0.93), dark: (0.085, 0.088, 0.095))
    public static let surface = adaptive("surface", light: (0.997, 0.992, 0.98), dark: (0.125, 0.13, 0.14))
    public static let accent = adaptive("accent", light: (0.77, 0.18, 0.135), dark: (0.93, 0.35, 0.28))
    public static let selection = Color(red: 0.73, green: 0.16, blue: 0.12)
    /// Compatibility for existing badges. Flat color, without the former multicolor gradient.
    public static var ember: LinearGradient {
        LinearGradient(colors: [selection, selection], startPoint: .top, endPoint: .bottom)
    }
    public static let cardRadius: CGFloat = 14
}

/// A settings-style icon: a white symbol on a small rounded square of its page's colour, lit
/// slightly from the top, like the icons in macOS System Settings. Colours are muted so they sit
/// beside the single vermilion accent without competing with it.
public struct MulgIcon: View {
    let symbol: String
    let tint: Color
    let size: CGFloat

    public init(_ symbol: String, tint: Color, size: CGFloat = 22) {
        self.symbol = symbol
        self.tint = tint
        self.size = size
    }

    public var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.54, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(tint.gradient))
            .overlay(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.14), radius: 0.6, y: 0.6)
            .accessibilityHidden(true)
    }
}

/// The icon colours, one per kind of page.
public enum MulgIconTint {
    private static func muted(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(red: red, green: green, blue: blue)
    }
    public static let blue = muted(0.22, 0.48, 0.86)
    public static let indigo = muted(0.38, 0.36, 0.82)
    public static let purple = muted(0.58, 0.36, 0.78)
    public static let pink = muted(0.86, 0.33, 0.52)
    public static let red = muted(0.84, 0.28, 0.24)
    public static let orange = muted(0.91, 0.52, 0.18)
    public static let yellow = muted(0.88, 0.68, 0.16)
    public static let green = muted(0.27, 0.66, 0.38)
    public static let teal = muted(0.18, 0.62, 0.66)
    public static let brown = muted(0.60, 0.46, 0.33)
    public static let gray = muted(0.50, 0.52, 0.56)
    public static let accent = MulgStyle.selection
}

private struct MulgAppearanceModifier: ViewModifier {
    @AppStorage(GUIKey.appearance) private var appearance = MulgAppearance.system
    func body(content: Content) -> some View {
        content.tint(MulgStyle.accent)
            .onAppear { appearance.apply() }
            .onChange(of: appearance) { appearance.apply() }
    }
}

struct MulgCard: ViewModifier {
    var radius: CGFloat
    @AppStorage(GUIKey.translucentWindow) private var translucent = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if translucent && !reduceTransparency && contrast != .increased {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(MulgStyle.surface, in: shape)
                .overlay(shape.strokeBorder(contrast == .increased
                    ? Color.primary.opacity(0.5) : Color.primary.opacity(scheme == .dark ? 0.12 : 0.065), lineWidth: 1))
        }
    }
}

struct MulgWindowBackground: ViewModifier {
    @AppStorage(GUIKey.translucentWindow) private var translucent = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        if translucent && !reduceTransparency && contrast != .increased {
            content.containerBackground(.ultraThinMaterial, for: .window)
        } else {
            content.containerBackground(contrast == .increased
                ? Color(nsColor: .windowBackgroundColor) : MulgStyle.canvas, for: .window)
        }
    }
}

/// Compatibility name: pages now use a quiet solid canvas instead of a glowing wash.
struct EmberGlow: View {
    @AppStorage(GUIKey.translucentWindow) private var translucent = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Rectangle().fill(translucent && !reduceTransparency && contrast != .increased
            ? .clear : contrast == .increased ? Color(nsColor: .windowBackgroundColor) : MulgStyle.canvas)
            .ignoresSafeArea().allowsHitTesting(false)
    }
}

/// Tiles and cards that answer a click: a short spring down while pressed (none with Reduce Motion).
public struct MulgPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.965 : 1)
            .brightness(configuration.isPressed ? -0.03 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A small live dot for a running game.
public struct MulgLiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init() {}
    public var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 7))
            .foregroundStyle(.green)
            .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            .accessibilityHidden(true)
    }
}

extension View {
    public func mulgCard(radius: CGFloat = MulgStyle.cardRadius) -> some View { modifier(MulgCard(radius: radius)) }
    public func mulgWindowBackground() -> some View { modifier(MulgWindowBackground()) }
    public func mulgAppearance() -> some View { modifier(MulgAppearanceModifier()) }
}
#endif
