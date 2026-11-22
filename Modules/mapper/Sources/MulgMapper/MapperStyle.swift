#if canImport(UIKit) && !os(watchOS)
import UIKit

/// Colours and small building blocks shared by the mapper's views.
@MainActor
enum MapperStyle {
    static let selection = UIColor.systemYellow
    static let conflict = UIColor.systemRed

    static func color(for tool: MapperTool) -> UIColor {
        switch tool {
        case .joystick: .systemGreen
        case .floatingJoystick: .systemTeal
        case .skill: .systemBlue
        case .camera: .systemPurple
        case .drag: .systemOrange
        }
    }

    /// A dark, blurred card, like the panels of a system overlay, readable on any scene.
    static func makeCard(cornerRadius: CGFloat = 14) -> UIVisualEffectView {
        let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
        card.layer.cornerRadius = cornerRadius
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        return card
    }

    static func makeLabel(size: CGFloat, weight: UIFont.Weight = .regular, color: UIColor = .white,
                          lines: Int = 1, alignment: NSTextAlignment = .natural) -> UILabel {
        let label = UILabel()
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.numberOfLines = lines
        label.textAlignment = alignment
        return label
    }

    static func symbol(_ name: String, size: CGFloat = 15, weight: UIImage.SymbolWeight = .semibold) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weight))
    }

    /// A tool button for the panels: a symbol, optionally a title.
    static func makeButton(title: String? = nil, symbol: String? = nil, role: Role = .plain) -> UIButton {
        var configuration: UIButton.Configuration
        switch role {
        case .plain:
            configuration = .plain()
            configuration.baseForegroundColor = .white
        case .tinted:
            configuration = .tinted()
            configuration.baseForegroundColor = .white
            configuration.baseBackgroundColor = .white
        case .primary:
            configuration = .filled()
            configuration.baseForegroundColor = .white
            configuration.baseBackgroundColor = .systemGreen
        case .destructive:
            configuration = .tinted()
            configuration.baseForegroundColor = .systemRed
            configuration.baseBackgroundColor = .systemRed
        }
        configuration.title = title
        configuration.image = symbol.flatMap { Self.symbol($0) }
        configuration.imagePadding = 6
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: title == nil ? 9 : 12, bottom: 7,
                                                              trailing: title == nil ? 9 : 12)
        let button = UIButton(configuration: configuration)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    enum Role { case plain, tinted, primary, destructive }
}
#endif
