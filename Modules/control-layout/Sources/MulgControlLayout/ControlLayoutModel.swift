import CoreGraphics
import Foundation
import MulgKeymaps

public enum HUDGroupAxis: String, Codable, Sendable { case row, column, cluster }

/// Identity is the existing binding address, not an inferred action/game name.
public struct HUDLayoutGroup: Sendable {
    public let id: String
    public let axis: HUDGroupAxis
    public let members: [ControlBindingAddress]
    public let horizontalAnchor: KeymapHorizontalAnchor
    public let verticalAnchor: KeymapVerticalAnchor
    public let referenceAspect: Double
}

public struct HUDLayoutPoint: Codable, Sendable, Equatable {
    public let address: ControlBindingAddress
    public var x: Double
    public var y: Double
    public var size: Double?
    public var available: Bool
    public init(address: ControlBindingAddress, point: CGPoint, size: Double? = nil, available: Bool = true) {
        self.address = address; x = Double(point.x); y = Double(point.y)
        self.size = size; self.available = available
    }
    public var point: CGPoint { CGPoint(x: x, y: y) }
    public var isValid: Bool {
        x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y)
            && (size.map { $0.isFinite && $0 > 0 && $0 <= 100 } ?? true)
            && address.layer >= 0 && address.index >= 0 && address.kind != .camera
    }
}

/// A genuine group observation. Rendering points and output pixels remain distinct;
/// the existing canvas supplies the logical render aspect, capture supplies the point aspect.
public struct HUDLayoutSample: Codable, Sendable, Equatable {
    public let groupID: String
    public let aspect: Double
    public let pointAspect: Double
    public let points: [HUDLayoutPoint]
    public let confidence: Double
    public let regime: String
    public init(groupID: String, aspect: Double, pointAspect: Double,
                points: [HUDLayoutPoint], confidence: Double, regime: String = "mapped") {
        self.groupID = groupID; self.aspect = aspect; self.pointAspect = pointAspect
        self.points = points; self.confidence = confidence; self.regime = regime
    }
    public var isValid: Bool {
        !groupID.isEmpty && groupID.count <= 4096 && !regime.isEmpty && regime.count <= 512
            && aspect.isFinite && (0.3...6).contains(aspect)
            && pointAspect.isFinite && (0.1...12).contains(pointAspect)
            && confidence.isFinite && (0.9...1).contains(confidence)
            && (2...32).contains(points.count) && points.allSatisfy(\.isValid)
            && points.filter(\.available).count >= 2
            && Set(points.map(\.address)).count == points.count
    }
    public var geometry: HUDGroupGeometry? { HUDGroupGeometry(points: points, aspect: aspect) }
}

public struct HUDGroupGeometry: Sendable {
    public let origin: CGPoint
    public let bounds: CGRect
    public let localOffsets: [ControlBindingAddress: CGVector]
    public init?(points: [HUDLayoutPoint], aspect: Double) {
        let visible = points.filter(\.available)
        guard visible.count >= 2, aspect.isFinite, aspect > 0, points.allSatisfy(\.isValid),
              Set(points.map(\.address)).count == points.count else { return nil }
        let x = visible.map(\.x).reduce(0, +) / Double(visible.count)
        let y = visible.map(\.y).reduce(0, +) / Double(visible.count)
        origin = CGPoint(x: x, y: y)
        bounds = CGRect(x: visible.map(\.x).min()!, y: visible.map(\.y).min()!,
            width: visible.map(\.x).max()! - visible.map(\.x).min()!,
            height: visible.map(\.y).max()! - visible.map(\.y).min()!)
        localOffsets = Dictionary(uniqueKeysWithValues: points.map {
            ($0.address, CGVector(dx: ($0.x - x) * aspect, dy: $0.y - y))
        })
    }
}

/// One atomic publication; a caller must preflight every affected action before adoption.
public struct HUDLayoutResolution: Sendable {
    public let groupID: String
    public let revision: UInt64
    public let aspect: Double
    public let points: [HUDLayoutPoint]
    public let observed: Bool
}

public enum HUDLayoutCatalog {
    public static func groups(in map: KeymappingData) -> [HUDLayoutGroup] {
        let aspect = map.mulgAspectRatio ?? 16.0 / 9
        guard aspect.isFinite, aspect > 0 else { return [] }
        var result: [HUDLayoutGroup] = []
        func scope(_ layer: Int, buttons: [ButtonElement], drags: [ButtonElement], profile: ControlMapProfile?) {
            let entries: [(ControlBindingAddress, ButtonElement)] = buttons.enumerated().map {
                (ControlBindingAddress(layer: layer, kind: .button, index: $0.offset), $0.element)
            } + drags.enumerated().map {
                (ControlBindingAddress(layer: layer, kind: .draggable, index: $0.offset), $0.element)
            }
            let eligible = entries.filter { $0.1.bindingName != nil && map.hudTarget(at: $0.0, aspect: aspect) != nil
                && !($0.1.transform.hudSamples ?? []).contains(where: { $0.source == .calibrated }) }
            var claimed: Set<ControlBindingAddress> = []
            func append(_ members: [(ControlBindingAddress, ButtonElement)], h: KeymapHorizontalAnchor,
                        v: KeymapVerticalAnchor, forcedAxis: HUDGroupAxis? = nil) {
                guard (2...16).contains(members.count), members.allSatisfy({ !claimed.contains($0.0) }) else { return }
                let xs = members.map { Double($0.1.transform.xCoord) }, ys = members.map { Double($0.1.transform.yCoord) }
                let dx = (xs.max()! - xs.min()!) * aspect, dy = ys.max()! - ys.min()!
                let axis = forcedAxis ?? (dx < 0.06 && dy > 0.04 ? .column : dy < 0.04 && dx > 0.04 ? .row : .cluster)
                let ordered = members.sorted {
                    axis == .column ? $0.1.transform.yCoord < $1.1.transform.yCoord
                        : axis == .row ? $0.1.transform.xCoord < $1.1.transform.xCoord : $0.0.index < $1.0.index
                }.map(\.0)
                let identity = ordered.map { "\($0.layer):\($0.kind.rawValue):\($0.index)" }.joined(separator: "|")
                result.append(HUDLayoutGroup(id: identity, axis: axis, members: ordered,
                    horizontalAnchor: h, verticalAnchor: v, referenceAspect: aspect))
                claimed.formUnion(ordered)
            }
            let authored = profile?.layoutGroups ?? []
            for group in authored {
                // Resolve overlapping authored membership explicitly below; never infer over it.
                let unambiguous = eligible.filter { entry in
                    group.contains(entry.1) && authored.filter { $0.contains(entry.1) }.count == 1
                }
                guard unambiguous.count == entries.filter({ group.contains($0.1) }).count else { continue }
                append(unambiguous, h: group.horizontalAnchor, v: group.verticalAnchor)
            }
            let excluded = Set(eligible.filter { entry in authored.contains { $0.contains(entry.1) } }.map(\.0))
            // Intentional aliases retain their existing independent tracking path.
            let uniqueGeometry = eligible.filter { entry in
                eligible.filter { other in
                    hypot(Double(entry.1.transform.xCoord - other.1.transform.xCoord) * aspect,
                          Double(entry.1.transform.yCoord - other.1.transform.yCoord)) < 0.012
                }.count == 1
            }
            for seed in uniqueGeometry where !claimed.contains(seed.0) && !excluded.contains(seed.0) {
                let t = seed.1.transform
                let rest = uniqueGeometry.filter { !claimed.contains($0.0) && !excluded.contains($0.0) }
                let column = rest.filter { abs($0.1.transform.xCoord - t.xCoord) * CGFloat(aspect) < 0.035
                    && abs($0.1.transform.yCoord - t.yCoord) < 0.42 }
                let row = rest.filter { abs($0.1.transform.yCoord - t.yCoord) < 0.02
                    && abs($0.1.transform.xCoord - t.xCoord) * CGFloat(aspect) < 0.5 }
                let candidates = (t.xCoord < 0.25 || t.xCoord > 0.75) && column.count >= 3 ? column
                    : (t.yCoord < 0.25 || t.yCoord > 0.75) && row.count >= 3 ? row : []
                guard candidates.count >= 3 else { continue }
                let x = candidates.map { $0.1.transform.xCoord }.reduce(0, +) / CGFloat(candidates.count)
                let y = candidates.map { $0.1.transform.yCoord }.reduce(0, +) / CGFloat(candidates.count)
                append(candidates, h: x < 0.3 ? .left : x > 0.7 ? .right : .center,
                       v: y < 0.35 ? .top : y > 0.65 ? .bottom : .center)
            }
        }
        scope(0, buttons: map.buttonModels, drags: map.draggableButtonModels, profile: map.mulgControlProfile)
        for (index, layer) in (map.mulgLayers ?? []).enumerated() where layer.hasHoldKey {
            scope(index + 1, buttons: layer.buttonModels, drags: layer.draggableButtonModels, profile: layer.mulgControlProfile)
        }
        return result
    }
}
