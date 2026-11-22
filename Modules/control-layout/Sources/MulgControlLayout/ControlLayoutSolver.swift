import CoreGraphics
import Foundation
import MulgKeymaps

/// Pure state machine: no windows, screenshots, input injection or game-specific semantics.
/// Published/imported map coordinates are immutable; only verified session evidence is applied.
public struct ControlLayoutSolver: Sendable {
    public private(set) var samples: [HUDLayoutSample] = []
    public private(set) var groups: [HUDLayoutGroup] = []
    private var verified: Set<String> = []
    private var activeRegimes: [String: String] = [:]
    public var verifiedGroupCount: Int { verified.count }

    public init(map: KeymappingData, cached: [HUDLayoutSample] = []) {
        let catalog = HUDLayoutCatalog.groups(in: map)
        let restored: [HUDLayoutSample] = cached.compactMap { sample in
            guard sample.isValid, let group = catalog.first(where: {
                $0.id == sample.groupID && Set($0.members) == Set(sample.points.map(\.address))
            }) else { return nil }
            return HUDLayoutSample(groupID: sample.groupID, aspect: sample.aspect, pointAspect: sample.pointAspect,
                points: group.members.compactMap { address in sample.points.first { $0.address == address } },
                confidence: sample.confidence, regime: sample.regime)
        }
        groups = catalog
        samples = Array(restored.suffix(96))
    }

    public func group(containing address: ControlBindingAddress) -> HUDLayoutGroup? {
        groups.first { $0.members.contains(address) }
    }

    public mutating func invalidateVerification() { verified.removeAll() }

    public mutating func invalidateVerification(for groupID: String) {
        verified.remove(groupID)
        activeRegimes[groupID] = nil
    }

    /// Uniform local coordinates preserve group orientation; layout scale never reaches
    /// movement/camera vectors. All observed members must agree, not just the best subset.
    public mutating func observe(group: HUDLayoutGroup, points: [HUDLayoutPoint], map: KeymappingData,
                                 aspect: Double, pointAspect: Double, confidence: Double,
                                 regime: String = "mapped", reflow: Bool = false,
                                 revision: UInt64 = 0) -> HUDLayoutResolution? {
        guard aspect.isFinite, aspect > 0, pointAspect.isFinite, pointAspect > 0,
              groups.contains(where: { $0.id == group.id && $0.members == group.members }),
              confidence >= 0.9, confidence <= 1, points.allSatisfy(\.isValid),
              Set(points.map(\.address)).count == points.count,
              Set(points.map(\.address)).isSubset(of: Set(group.members)) else { return nil }
        let visible = points.filter(\.available)
        guard visible.count >= 2 else { return nil }
        let baseline = group.members.compactMap { map.hudTarget(at: $0, aspect: aspect) }
        guard baseline.count == group.members.count else { return nil }
        for (i, a) in visible.enumerated() {
            for b in visible.dropFirst(i + 1) {
                let separation = hypot((a.x - b.x) * aspect, a.y - b.y)
                if separation <= 0.018 {
                    guard let ta = baseline.first(where: { $0.address == a.address }),
                          let tb = baseline.first(where: { $0.address == b.address }),
                          hypot(Double(ta.transform.xCoord - tb.transform.xCoord) * aspect,
                                Double(ta.transform.yCoord - tb.transform.yCoord)) < 0.012,
                          separation < 0.009 else { return nil }
                }
            }
        }
        var resolved = points
        if !reflow {
            // Missing or reordered rows are a different layout regime, not a translation.
            guard visible.count == group.members.count else { return nil }
            let pairs = visible.compactMap { point -> (CGPoint, CGPoint)? in
                guard let target = baseline.first(where: { $0.address == point.address }) else { return nil }
                return (CGPoint(x: Double(target.transform.xCoord) * aspect, y: Double(target.transform.yCoord)),
                        CGPoint(x: point.x * aspect, y: point.y))
            }
            guard pairs.count == visible.count else { return nil }
            let n = CGFloat(pairs.count)
            let a = pairs.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.0.x / n, y: $0.y + $1.0.y / n) }
            let b = pairs.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.1.x / n, y: $0.y + $1.1.y / n) }
            let denominator = pairs.reduce(CGFloat.zero) { $0 + pow($1.0.x - a.x, 2) + pow($1.0.y - a.y, 2) }
            guard denominator > 0.0001 else { return nil }
            let scale = pairs.reduce(CGFloat.zero) {
                $0 + ($1.0.x - a.x) * ($1.1.x - b.x) + ($1.0.y - a.y) * ($1.1.y - b.y)
            } / denominator
            guard scale.isFinite, (0.45...2.2).contains(scale), hypot(a.x - b.x, a.y - b.y) < 0.45,
                  pairs.allSatisfy({ hypot(b.x + ($0.0.x - a.x) * scale - $0.1.x,
                                          b.y + ($0.0.y - a.y) * scale - $0.1.y) < 0.012 }) else { return nil }
            resolved = visible.map { original in
                var point = original
                if point.size == nil, let target = baseline.first(where: { $0.address == point.address }) {
                    point.size = Double(target.transform.size * scale)
                }
                return point
            }
        } else {
            guard points.count == group.members.count else { return nil }
            let ordered = group.members.compactMap { address in visible.first { $0.address == address } }
            guard ordered.count == visible.count else { return nil }
        }
        // Canonical binding order keeps availability signatures stable even when a
        // native/visual observer reports members in a different order.
        resolved = group.members.compactMap { address in resolved.first { $0.address == address } }
        let sample = HUDLayoutSample(groupID: group.id, aspect: aspect, pointAspect: pointAspect,
            points: resolved, confidence: confidence, regime: regime)
        guard sample.isValid else { return nil }
        samples.removeAll { $0.groupID == group.id && $0.regime == regime && abs(log($0.aspect / aspect)) < 0.01
            && abs(log($0.pointAspect / pointAspect)) < 0.01 }
        samples.append(sample)
        if samples.count > 96 { samples.removeFirst(samples.count - 96) }
        verified.insert(group.id); activeRegimes[group.id] = regime
        return HUDLayoutResolution(groupID: group.id, revision: revision, aspect: aspect, points: resolved, observed: true)
    }

    /// Cached samples are useful search seeds but cannot be applied before live verification.
    public func prediction(for group: HUDLayoutGroup, aspect: Double, revision: UInt64, pointAspect: Double? = nil,
                           includeUnverified: Bool = false) -> HUDLayoutResolution? {
        guard aspect.isFinite, aspect > 0,
              pointAspect.map({ $0.isFinite && $0 > 0 }) ?? true,
              includeUnverified || verified.contains(group.id) else { return nil }
        let available = samples.filter { $0.groupID == group.id }
        func distance(_ sample: HUDLayoutSample) -> Double {
            abs(log(sample.aspect / aspect)) + (pointAspect.map { abs(log(sample.pointAspect / $0)) } ?? 0)
        }
        guard let nearest = available.min(by: { distance($0) < distance($1) }) else { return nil }
        if !includeUnverified, let pointAspect,
           abs(log((nearest.pointAspect / nearest.aspect) / (pointAspect / aspect))) > 0.025 { return nil }
        let regime = activeRegimes[group.id] ?? nearest.regime
        guard let selected = available.filter({ $0.regime == regime }).min(by: { distance($0) < distance($1) }) else { return nil }
        let compatible = available.filter { $0.regime == regime && $0.points.map(\.available) == selected.points.map(\.available)
            && abs(log(($0.pointAspect / $0.aspect) / (selected.pointAspect / selected.aspect))) < 0.025 }
            .sorted { $0.aspect < $1.aspect }
        let lower = compatible.last { $0.aspect <= aspect }, upper = compatible.first { $0.aspect >= aspect }
        var points: [HUDLayoutPoint]
        if let lower, let upper, upper.aspect - lower.aspect > 0.002 {
            let t = (aspect - lower.aspect) / (upper.aspect - lower.aspect)
            let tx = (1 / aspect - 1 / lower.aspect) / (1 / upper.aspect - 1 / lower.aspect)
            points = lower.points.compactMap { a in
                guard let b = upper.points.first(where: { $0.address == a.address && $0.available == a.available }) else { return nil }
                var p = a; p.x += (b.x - a.x) * tx; p.y += (b.y - a.y) * t
                if let sa = a.size, let sb = b.size {
                    p.size = (sa * max(1, lower.aspect) * (1 - t) + sb * max(1, upper.aspect) * t) / max(1, aspect)
                }
                return p
            }
        } else {
            let source = lower ?? upper ?? selected
            guard let canvas = KeymapCanvas(referenceAspectRatio: source.aspect, viewportAspectRatio: aspect),
                  let frame = source.geometry else { return nil }
            let origin = canvas.fitted(KeyModelTransform(size: 1, xCoord: frame.origin.x, yCoord: frame.origin.y,
                horizontalAnchor: group.horizontalAnchor, verticalAnchor: group.verticalAnchor))
            points = source.points.compactMap { original in
                guard let local = frame.localOffsets[original.address] else { return nil }
                var p = original
                p.x = Double(origin.xCoord + local.dx * canvas.scaleInHeights / CGFloat(aspect))
                p.y = Double(origin.yCoord + local.dy * canvas.scaleInHeights)
                if let size = original.size {
                    p.size = size * max(source.aspect, 1) / max(aspect, 1) * Double(canvas.scaleInHeights)
                }
                return p
            }
        }
        guard points.count == group.members.count, points.allSatisfy(\.isValid) else { return nil }
        return HUDLayoutResolution(groupID: group.id, revision: revision, aspect: aspect, points: points, observed: false)
    }
}
