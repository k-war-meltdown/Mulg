import CoreGraphics
import Foundation

public enum ControlHUDSampleSource: String, Codable, Sendable {
    case reference, published, projected, calibrated, learned
}

/// A control's location at one aspect ratio. Observations, learned group translations and
/// mathematical projections remain distinguishable; resizing never rewrites their plane.
public struct ControlHUDSample: Codable, Sendable, Equatable {
    public var aspectRatio: Double
    public var xCoord: CGFloat
    public var yCoord: CGFloat
    public var size: CGFloat
    public var source: ControlHUDSampleSource?

    public init(aspectRatio: Double, xCoord: CGFloat, yCoord: CGFloat, size: CGFloat,
                source: ControlHUDSampleSource? = nil) {
        self.aspectRatio = aspectRatio
        self.xCoord = xCoord
        self.yCoord = yCoord
        self.size = size
        self.source = source
    }

    public var isObserved: Bool { source == nil || source == .published || source == .calibrated }
    public var isValid: Bool {
        aspectRatio.isFinite && aspectRatio > 0 && xCoord.isFinite && yCoord.isFinite
            && size.isFinite && size > 0 && (0...1).contains(xCoord) && (0...1).contains(yCoord)
    }
}

extension KeyModelTransform {
    /// Retain real measurements at other shapes and the immutable baseline. Generated
    /// corrections are rebuilt from evidence rather than mistaken for new observations.
    public mutating func recordHUDSample(at aspect: Double) {
        let sample = ControlHUDSample(aspectRatio: aspect, xCoord: xCoord, yCoord: yCoord, size: size,
                                      source: .calibrated)
        guard sample.isValid else { return }
        if hudBaselines == nil {
            let originals = (hudSamples ?? []).filter {
                $0.isValid && ($0.isObserved && $0.source != .calibrated || $0.source == .reference)
            }
            if !originals.isEmpty { hudBaselines = originals }
        }
        var samples = (hudSamples ?? []).filter {
            $0.isValid && $0.source != .projected && $0.source != .learned
                && abs(log($0.aspectRatio / aspect)) > 0.002
        }
        samples.append(sample)
        samples.sort { $0.aspectRatio < $1.aspectRatio }
        if samples.count > 32 {
            let remove = samples.indices.filter { samples[$0] != sample }.min {
                abs(log(samples[$0].aspectRatio / aspect)) < abs(log(samples[$1].aspectRatio / aspect))
            }
            if let remove { samples.remove(at: remove) }
        }
        hudSamples = samples
    }

    /// Original published/reference positions, never editor adjustments or learned output.
    /// A legacy map with no trustworthy baseline cannot produce a group correction.
    public func baselineHUDTransform(at aspect: Double) -> KeyModelTransform? {
        let baseline = (hudBaselines ?? []).filter {
            $0.isValid && ($0.isObserved && $0.source != .calibrated || $0.source == .reference)
        }
        let originals = baseline.isEmpty ? (hudSamples ?? []).filter {
            $0.isValid && ($0.isObserved && $0.source != .calibrated || $0.source == .reference)
        } : baseline
        let published = originals.filter { $0.isObserved }
        return resolvedHUDTransform(published.isEmpty ? originals : published, at: aspect, retainMetadata: false)
    }

    public func measuredHUDTransform(at aspect: Double) -> KeyModelTransform? {
        let valid = (hudSamples ?? []).filter(\.isValid)
        // Learned sibling positions can extend an observed range, but never replace an
        // individual observation at the same shape. References/projections stay subordinate.
        let evidence = valid.filter { $0.isObserved || $0.source == .learned }
        return resolvedHUDTransform(evidence.isEmpty ? valid : evidence, at: aspect, retainMetadata: true)
    }

    private func resolvedHUDTransform(_ input: [ControlHUDSample], at aspect: Double,
                                      retainMetadata: Bool) -> KeyModelTransform? {
        guard aspect.isFinite, aspect > 0 else { return nil }
        func rank(_ sample: ControlHUDSample) -> Int {
            switch sample.source {
            case .calibrated: 4
            case .published, nil: 3
            case .learned: 2
            case .reference: 1
            case .projected: 0
            }
        }
        var samples: [ControlHUDSample] = []
        for sample in input.sorted(by: {
            let a = rank($0), b = rank($1)
            return a == b ? $0.aspectRatio < $1.aspectRatio : a > b
        }) where !samples.contains(where: { abs(log($0.aspectRatio / sample.aspectRatio)) < 0.002 }) {
            samples.append(sample)
        }
        samples.sort { $0.aspectRatio < $1.aspectRatio }
        guard let first = samples.first, let last = samples.last else { return nil }
        func transform(_ sample: ControlHUDSample) -> KeyModelTransform {
            KeyModelTransform(size: sample.size, xCoord: sample.xCoord, yCoord: sample.yCoord,
                horizontalAnchor: horizontalAnchor, verticalAnchor: verticalAnchor)
        }
        var resolved: KeyModelTransform
        if aspect <= first.aspectRatio {
            resolved = transform(first).fitted(from: first.aspectRatio, to: aspect)
        } else if aspect >= last.aspectRatio {
            resolved = transform(last).fitted(from: last.aspectRatio, to: aspect)
        } else {
            guard let upper = samples.firstIndex(where: { $0.aspectRatio >= aspect }), upper > 0 else { return nil }
            let a = samples[upper - 1], b = samples[upper]
            let vertical = CGFloat((aspect - a.aspectRatio) / (b.aspectRatio - a.aspectRatio))
            let horizontal = CGFloat((1 / aspect - 1 / a.aspectRatio) / (1 / b.aspectRatio - 1 / a.aspectRatio))
            func blend(_ start: CGFloat, _ end: CGFloat, _ t: CGFloat) -> CGFloat { start + (end - start) * t }
            let sizeInHeights = blend(a.size * CGFloat(max(1, a.aspectRatio)),
                                     b.size * CGFloat(max(1, b.aspectRatio)), vertical)
            resolved = KeyModelTransform(size: sizeInHeights / CGFloat(max(1, aspect)),
                xCoord: blend(a.xCoord, b.xCoord, horizontal), yCoord: blend(a.yCoord, b.yCoord, vertical),
                horizontalAnchor: horizontalAnchor, verticalAnchor: verticalAnchor)
        }
        if retainMetadata {
            resolved.hudSamples = hudSamples
            resolved.hudBaselines = hudBaselines
        }
        resolved.widthScale = widthScale
        resolved.heightScale = heightScale
        return resolved
    }
}
