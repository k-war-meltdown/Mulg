import Foundation
import MulgContracts

/// A short message shown on top of the game, such as "MetalFX on: Balanced (67 %)".
public struct Notice: Sendable, Equatable {
    public enum Style: Sendable, Equatable {
        case info
        case warning
    }

    public let title: String
    public let lines: [String]
    public let style: Style
    public let duration: Duration
    /// Shown even while notices are hidden (a full-screen game in performance mode): progress of
    /// something the player started and is waiting on, such as a calibration.
    public let important: Bool

    public init(_ title: String, lines: [String] = [], style: Style = .info, duration: Duration = .seconds(3),
                important: Bool = false) {
        self.title = title
        self.lines = lines
        self.style = style
        self.duration = duration
        self.important = important
    }
}

/// Shows notices. The runtime installs a UIKit presenter; tests and early start-up use the
/// log-only one.
@MainActor
public protocol NoticePresenter: AnyObject {
    func show(_ notice: Notice)
    /// Keep wrapper overlays out of user-confirmed visual references.
    func setVisualCaptureSuppressed(_ suppressed: Bool)
}

extension NoticePresenter {
    public func setVisualCaptureSuppressed(_ suppressed: Bool) {}
}

/// Writes notices to the log only.
@MainActor
public final class LogNoticePresenter: NoticePresenter {
    public private(set) var shown: [Notice] = []
    public init() {}

    public func show(_ notice: Notice) {
        shown.append(notice)
        MulgLog.logger(.engine).notice(
            "Notice: \(notice.title, privacy: .public) \(notice.lines.joined(separator: " "), privacy: .public)")
    }
}

/// Queues notices until a real presenter is available (the window exists only after the
/// first scene is active), then hands them over in order.
@MainActor
public final class NoticeCenter: NoticePresenter {
    private var pending: [Notice] = []
    private var presenter: (any NoticePresenter)?
    private var captureTokens: Set<UUID> = []
    /// While this returns true, notices are only logged: a panel on top of a full-screen game makes
    /// macOS composite the screen, which costs a frame of latency (§5.4).
    public var hideWhile: (@MainActor () -> Bool)?

    public init() {}

    public func attach(_ presenter: any NoticePresenter) {
        self.presenter = presenter
        presenter.setVisualCaptureSuppressed(!captureTokens.isEmpty)
        let queued = pending
        pending.removeAll()
        for notice in queued {
            show(notice)
        }
    }

    public func show(_ notice: Notice) {
        if !captureTokens.isEmpty {
            pending.append(notice)
            if pending.count > 16 { pending.removeFirst(pending.count - 16) }
            return
        }
        if hideWhile?() == true, !notice.important {
            LogNoticePresenter().show(notice)
            return
        }
        if let presenter {
            presenter.show(notice)
        } else {
            pending.append(notice)
            MulgLog.logger(.engine).info("Queued notice: \(notice.title, privacy: .public)")
        }
    }

    /// Balanced leases also cover an older cancelled capture finishing after a newer one.
    public func beginVisualCapture() -> UUID {
        let token = UUID(); captureTokens.insert(token)
        presenter?.setVisualCaptureSuppressed(true)
        return token
    }

    public func endVisualCapture(_ token: UUID) {
        guard captureTokens.remove(token) != nil, captureTokens.isEmpty else { return }
        presenter?.setVisualCaptureSuppressed(false)
        let queued = pending; pending.removeAll()
        for notice in queued { show(notice) }
    }
}

#if canImport(UIKit) && !os(watchOS)
import UIKit

/// Notices as small rounded panels at the top of the game window, stacked, at most four.
/// Simplified from upstream's Toast.swift; never takes input, so it can't block the game.
@MainActor
public final class ToastPresenter: NoticePresenter {
    private weak var window: UIWindow?
    private var visible: [UIView] = []
    private let gap: CGFloat = 12
    private let maximumVisible = 4
    private var captureSuppressed = false

    public func setVisualCaptureSuppressed(_ suppressed: Bool) {
        captureSuppressed = suppressed
        visible.forEach { $0.isHidden = suppressed }
    }

    public init(window: UIWindow) {
        self.window = window
    }

    public func show(_ notice: Notice) {
        guard let window else { return }

        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.attributedText = Self.text(for: notice)
        let maximumWidth = min(window.bounds.width - 40, 720)
        let textSize = label.sizeThatFits(CGSize(width: maximumWidth - 32, height: .greatestFiniteMagnitude))

        let panel = UIView(frame: CGRect(x: 0, y: 0, width: textSize.width + 32, height: textSize.height + 20))
        panel.isUserInteractionEnabled = false
        panel.isHidden = captureSuppressed
        panel.backgroundColor = notice.style == .warning
            ? UIColor.systemOrange.withAlphaComponent(0.85)
            : UIColor.black.withAlphaComponent(0.6)
        panel.layer.cornerCurve = .continuous
        panel.layer.cornerRadius = 12
        label.frame = panel.bounds.insetBy(dx: 16, dy: 10)
        panel.addSubview(label)

        panel.center.x = window.bounds.midX
        panel.frame.origin.y = -panel.frame.height
        window.addSubview(panel)
        visible.append(panel)
        if visible.count > maximumVisible, let oldest = visible.first {
            hide(oldest)
        }
        layout(animated: true)

        let duration = notice.duration
        Task { @MainActor [weak self, weak panel] in
            try? await Task.sleep(for: duration)
            if let panel { self?.hide(panel) }
        }
    }

    private func hide(_ panel: UIView) {
        guard let index = visible.firstIndex(of: panel) else { return }
        visible.remove(at: index)
        UIView.animate(withDuration: 0.3, animations: { panel.alpha = 0 }, completion: { _ in
            panel.removeFromSuperview()
        })
        layout(animated: true)
    }

    private func layout(animated: Bool) {
        var y = (window?.safeAreaInsets.top ?? 0) + gap
        for panel in visible {
            let target = y
            let change = { panel.frame.origin.y = target }
            if animated {
                UIView.animate(withDuration: 0.3, animations: change)
            } else {
                change()
            }
            y += panel.frame.height + gap
        }
    }

    private static func text(for notice: Notice) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let result = NSMutableAttributedString(string: notice.title, attributes: [
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph
        ])
        for line in notice.lines {
            result.append(NSAttributedString(string: "\n" + line, attributes: [
                .font: UIFont.systemFont(ofSize: 14),
                .foregroundColor: UIColor.white.withAlphaComponent(0.9),
                .paragraphStyle: paragraph
            ]))
        }
        return result
    }
}
#endif
