import CoreGraphics
import Foundation
import MulgKeymaps

public struct HUDBootstrapGroup: Sendable {
    public let points: [HUDLayoutPoint]
    public let anchors: [ControlHUDAnchor]
    public let confidence: Double
}

/// Recover a displaced row/column without game-specific recognition or invented keys.
/// Every member needs a ring/glyph and a unique self-match. Multiple plausible group
/// locations are rejected; the runtime still requires three agreeing captures.
public enum HUDGroupBootstrap {
    public static func discover(group: HUDLayoutGroup, targets: [HUDControlTarget], image: HUDGrayImage,
                                aspect: Double) -> HUDBootstrapGroup? {
        guard group.axis != .cluster, (3...8).contains(group.members.count), aspect.isFinite, aspect > 0 else { return nil }
        let members = group.members.compactMap { address in targets.first { $0.address == address } }
        guard members.count == group.members.count else { return nil }
        let center = CGPoint(x: members.map { $0.transform.xCoord }.reduce(0, +) / CGFloat(members.count),
                             y: members.map { $0.transform.yCoord }.reduce(0, +) / CGFloat(members.count))
        var hypotheses: [(Double, Double, Double)] = []
        for dy in [0.0, -0.08, 0.08, -0.16, 0.16] {
            for dx in [0.0, -0.08, 0.08] { hypotheses.append((dx, dy, 1)) }
        }
        for scale in [0.85, 1.15] { for dy in [0.0, -0.08, 0.08] { hypotheses.append((0, dy, scale)) } }
        var solutions: [HUDBootstrapGroup] = []
        for (dx, dy, scale) in hypotheses {
            if Task.isCancelled { return nil }
            let shifted = members.map { target -> HUDControlTarget in
                var t = target.transform
                t.xCoord = center.x + (t.xCoord - center.x) * CGFloat(scale) + CGFloat(dx / aspect)
                t.yCoord = center.y + (t.yCoord - center.y) * CGFloat(scale) + CGFloat(dy)
                t.size *= CGFloat(scale)
                return HUDControlTarget(address: target.address, bindingSignature: target.bindingSignature, transform: t)
            }
            guard shifted.allSatisfy({ (0...1).contains($0.transform.xCoord) && (0...1).contains($0.transform.yCoord) }) else { continue }
            let candidates = HUDAutomaticDiscovery.discover(in: image, targets: shifted, aspect: aspect)
            guard candidates.count == members.count else { continue }
            let points = group.members.compactMap { address -> HUDLayoutPoint? in
                guard let candidate = candidates.first(where: { $0.anchor.address == address }) else { return nil }
                return HUDLayoutPoint(address: address, point: candidate.point)
            }
            guard HUDGroupSearch.coherent(points, group: group, aspect: aspect) else { continue }
            var scores: [Double] = []
            for candidate in candidates {
                guard let match = HUDAnchorMatcher.match(candidate.anchor, in: image, expected: candidate.point,
                    scaleInHeights: 1, searchRadiusInHeights: 0.055, viewportAspect: aspect), match.isConfident,
                      hypot(Double(match.point.x - candidate.point.x) * aspect, Double(match.point.y - candidate.point.y)) < 0.007 else { break }
                scores.append(match.confidence)
            }
            guard scores.count == candidates.count else { continue }
            let score = min(1, scores.min()!)
            if solutions.contains(where: { old in zip(old.points, points).allSatisfy {
                hypot(($0.0.x - $0.1.x) * aspect, $0.0.y - $0.1.y) < 0.012
            } }) { continue }
            solutions.append(HUDBootstrapGroup(points: points, anchors: candidates.map(\.anchor), confidence: score))
        }
        guard let best = solutions.max(by: { $0.confidence < $1.confidence }),
              solutions.filter({ $0.points != best.points }).allSatisfy({ best.confidence - $0.confidence >= 0.055 }) else { return nil }
        return best
    }
}
