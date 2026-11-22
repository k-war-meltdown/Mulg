import Foundation
import MulgContracts

/// The lines the performance overlay shows (§13.4), kept apart from UIKit so they are tested.
public enum OverlayText {
    public struct State: Sendable, Equatable {
        public var recentFPS: Double?
        public var frames: FrameStats.Summary?
        public var latency: LatencyTracker.Summary?
        public var metalFX: MetalFXPreset?
        public var refreshRate: Int?
        /// The Mac is really seriously hot (the game is told nominal).
        public var hot: Bool

        public init(recentFPS: Double? = nil, frames: FrameStats.Summary? = nil, latency: LatencyTracker.Summary? = nil,
                    metalFX: MetalFXPreset? = nil, refreshRate: Int? = nil, hot: Bool = false) {
            self.recentFPS = recentFPS
            self.frames = frames
            self.latency = latency
            self.metalFX = metalFX
            self.refreshRate = refreshRate
            self.hot = hot
        }
    }

    public static func lines(_ state: State) -> [String] {
        var lines: [String] = []
        if let fps = state.recentFPS {
            var line = "\(Int(fps.rounded())) FPS"
            if let low = state.frames?.onePercentLowFPS {
                line += " · 1% low \(Int(low.rounded()))"
            }
            lines.append(line)
        } else {
            lines.append("— FPS (waiting for frames)")
        }
        if let frames = state.frames {
            lines.append(String(format: "%.1f ms · worst %.1f ms · ±%.1f", frames.averageFrameTimeMs,
                                frames.worstFrameTimeMs, frames.frameTimeDeviationMs))
        }
        if let latency = state.latency {
            lines.append(String(format: "Input→next present ≈%.0f ms (p95 %.0f)", latency.medianMs, latency.p95Ms))
        }
        var last: [String] = []
        if let refresh = state.refreshRate, refresh > 0 {
            last.append("\(refresh) Hz")
        }
        last.append(state.metalFX.map { "MetalFX \($0.label)" } ?? "MetalFX off")
        if state.hot {
            last.append("Mac hot")
        }
        lines.append(last.joined(separator: " · "))
        return lines
    }
}

#if canImport(UIKit) && !os(watchOS)
import UIKit

/// A small read-only panel in the top-left corner of the game. It never takes input. Any view
/// over a Metal layer makes presentation composited rather than direct (§5.4), so it is off by
/// default and its cost shows in its own numbers.
final class PerformanceOverlayView: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = UIColor.black.withAlphaComponent(0.55)
        layer.cornerRadius = 6
        label.numberOfLines = 0
        label.textColor = .white
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show(_ lines: [String]) {
        label.text = lines.joined(separator: "\n")
        let size = label.sizeThatFits(CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
        label.frame = CGRect(x: 8, y: 6, width: size.width, height: size.height)
        guard let superview else { return }
        let inset = superview.safeAreaInsets
        frame = CGRect(x: inset.left + 8, y: inset.top + 8, width: size.width + 16, height: size.height + 12)
    }
}
#endif
