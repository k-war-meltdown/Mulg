import CoreGraphics
import Foundation
import MulgKeymaps

public enum HUDGroupSearch {
    /// Visibility/order topology forms a separate interpolation regime. A row-to-grid
    /// transition or reordered targets cannot be blended into the former arrangement.
    public static func regime(for points: [HUDLayoutPoint], aspect: Double) -> String {
        let visible = points.filter(\.available)
        guard visible.count >= 2 else { return "unknown" }
        let xs = visible.map(\.x), ys = visible.map(\.y)
        let axis = (xs.max()! - xs.min()!) * aspect < 0.045 ? "column"
            : ys.max()! - ys.min()! < 0.035 ? "row" : "cluster"
        let ordered = visible.sorted { axis == "column" ? $0.y < $1.y : $0.x < $1.x }
        let identity = ordered.map { "\($0.address.layer):\($0.address.kind.rawValue):\($0.address.index)" }.joined(separator: ",")
        return "\(axis):\(identity)"
    }
    /// Search an edge region around the whole group, including possible HUD reflow.
    /// Bounds use visible-surface fractions; logical render aspect owns horizontal units.
    public static func region(for group: HUDLayoutGroup, targets: [HUDControlTarget], aspect: Double) -> CGRect? {
        let members = targets.filter { group.members.contains($0.address) }
        guard members.count >= 2, aspect.isFinite, aspect > 0 else { return nil }
        let xs = members.map { Double($0.transform.xCoord) }, ys = members.map { Double($0.transform.yCoord) }
        let left = max(0, xs.min()! - 0.18 / aspect), right = min(1, xs.max()! + 0.18 / aspect)
        let top = max(0.03, ys.min()! - 0.24), bottom = min(0.97, ys.max()! + 0.24)
        let result = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        return result.width > 0 && result.height > 0 && result.width * result.height <= 0.28 ? result : nil
    }

    /// Distinct confident matches and preserved ordering are required before group fitting.
    public static func coherent(_ points: [HUDLayoutPoint], group: HUDLayoutGroup, aspect: Double) -> Bool {
        guard points.count >= 2, aspect.isFinite, aspect > 0, points.allSatisfy(\.isValid) else { return false }
        let sorted = group.members.compactMap { address in points.first { $0.address == address && $0.available } }
        guard sorted.count >= 2 else { return false }
        for pair in zip(sorted, sorted.dropFirst()) {
            guard hypot((pair.0.x - pair.1.x) * aspect, pair.0.y - pair.1.y) > 0.018 else { return false }
            if group.axis == .column && pair.0.y >= pair.1.y { return false }
            if group.axis == .row && pair.0.x >= pair.1.x { return false }
        }
        return true
    }
}

public struct HUDRepeatedRows: Sendable {
    public let centers: [Double]
    public let confidence: Double
}

/// Bootstrap a repeated text-bearing HUD column within a constrained edge region.
/// This supplies geometry only. A game adapter decides whether a reduced row count is meaningful.
public enum HUDRepeatedRowDiscovery {
    public static func find(in image: HUDGrayImage, region: CGRect, expectedGap: Double,
                            allowedCounts: Set<Int>) -> HUDRepeatedRows? {
        guard image.isValid, image.width >= 32, image.height >= 64,
              expectedGap.isFinite, (0.04...0.2).contains(expectedGap),
              !allowedCounts.isEmpty, allowedCounts.allSatisfy({ (3...6).contains($0) }) else { return nil }
        let area = region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !area.isNull, area.width * area.height <= 0.28 else { return nil }
        let pixels = Array(image.pixels), w = image.width, h = image.height
        let x0 = max(2, Int(area.minX * Double(w))), x1 = min(w - 3, Int(area.maxX * Double(w)))
        let y0 = max(2, Int(area.minY * Double(h))), y1 = min(h - 3, Int(area.maxY * Double(h)))
        guard x1 > x0, y1 > y0 else { return nil }
        var ink = [Int](repeating: 0, count: h)
        for y in y0...y1 {
            if Task.isCancelled { return nil }
            for x in x0...x1 {
                let i = y * w + x, value = Int(pixels[i])
                if value >= 220 && (abs(value - Int(pixels[i - 2])) > 35 || abs(value - Int(pixels[i + 2])) > 35) {
                    ink[y] += 1
                }
            }
        }
        let threshold = max(5, Int(Double(h) * 0.012))
        var bands: [(center: Double, strength: Double)] = []
        var start: Int?, lastInk = y0
        func finish(_ end: Int) {
            guard let first = start else { return }
            let length = end - first + 1
            if length >= 2 && Double(length) <= Double(h) * 0.035 {
                let weight = (first...end).reduce(0) { $0 + ink[$1] }
                if weight >= threshold * 3 {
                    let center = (first...end).reduce(0.0) { $0 + Double($1 * ink[$1]) } / Double(weight)
                    bands.append((center / Double(h), min(1, Double(weight) / Double(threshold * 6))))
                }
            }
            start = nil
        }
        for y in y0...y1 {
            if ink[y] >= threshold { if start == nil { start = y }; lastInk = y }
            else if start != nil, y - lastInk > 2 { finish(lastInk) }
        }
        finish(lastInk)
        guard bands.count >= 3, bands.count <= 40 else { return nil }
        var candidates: [(score: Double, rows: [Double])] = []
        for count in allowedCounts.sorted() {
            guard bands.count >= count else { continue }
            for i in 0...(bands.count - count) {
                let sequence = Array(bands[i..<(i + count)])
                let rows = sequence.map(\.center), gaps = zip(rows, rows.dropFirst()).map { $0.1 - $0.0 }
                let gap = gaps.reduce(0, +) / Double(gaps.count)
                guard (0.055...0.17).contains(gap), abs(log(gap / expectedGap)) < 0.45,
                      gaps.allSatisfy({ abs($0 - gap) < max(0.009, gap * 0.12) }) else { continue }
                // Text centroids vary slightly with the glyphs in each name. Keep the
                // hard spacing/ambiguity gates while tolerating that sub-row variation.
                let regularity = 1 - min(1, gaps.map { abs($0 - gap) / gap }.max()! / 0.5)
                let strength = sequence.map(\.strength).reduce(0, +) / Double(count)
                candidates.append((0.65 * regularity + 0.35 * strength, rows))
            }
        }
        guard let best = candidates.max(by: { $0.score + Double($0.rows.count) * 0.01 < $1.score + Double($1.rows.count) * 0.01 }),
              best.score >= 0.93 else { return nil }
        let second = candidates.filter { candidate in
            if candidate.rows.count < best.rows.count,
               candidate.rows.allSatisfy({ row in best.rows.contains { abs($0 - row) < 0.015 } }) { return false }
            return candidate.rows.count != best.rows.count || zip(candidate.rows, best.rows).contains { abs($0.0 - $0.1) > 0.015 }
        }.map(\.score).max() ?? 0
        guard best.score - second >= 0.055 else { return nil }
        return HUDRepeatedRows(centers: best.rows, confidence: best.score)
    }
}
