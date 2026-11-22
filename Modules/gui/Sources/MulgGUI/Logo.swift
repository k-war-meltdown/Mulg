// Host-side module: the Mulg app is native macOS, never Mac Catalyst.
#if os(macOS) && !targetEnvironment(macCatalyst)
import SwiftUI

/// The Mulg app icon as the app shows it: always its light version (it reads best on both window
/// appearances), on a soft blue halo with a gentle shadow, so it sits on the window rather than
/// on top of it. The halo spreads past `size`; the layout size stays `size`.
public struct MulgLogo: View {
    public var size: CGFloat
    /// Retained for source compatibility; the identity itself stays still and crisp.
    public var animated: Bool
    public init(size: CGFloat = 64, animated: Bool = false) { self.size = size; self.animated = animated }

    /// The pale blue of the icon's glass layers.
    private static let halo = Color(red: 0.55, green: 0.70, blue: 0.95)

    public var body: some View {
        Image("MulgAppIcon", bundle: .module)
            .resizable().renderingMode(.original)
            .scaledToFit()
            // Resolve the light asset whatever the window's appearance.
            .environment(\.colorScheme, .light)
            .shadow(color: .black.opacity(0.18), radius: size * 0.06, y: size * 0.035)
            .frame(width: size, height: size)
            .background {
                Circle()
                    .fill(RadialGradient(colors: [Self.halo.opacity(0.45), Self.halo.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: size * 0.85))
                    .frame(width: size * 1.7, height: size * 1.7)
                    .blur(radius: size * 0.08)
                    .allowsHitTesting(false)
            }
            .accessibilityLabel(Text(verbatim: "Mulg"))
    }
}

#endif
