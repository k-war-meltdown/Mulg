import CoreGraphics
import Foundation

/// A translation learned from independent editor measurements at one HUD shape.
/// Offsets use canvas-height units so horizontal motion is independent of aspect ratio.
public struct ControlGroupAdjustment: Sendable, Equatable {
    public let group: String
    public let aspectRatio: Double
    public let horizontalOffset: CGFloat
    public let verticalOffset: CGFloat
    public let measurements: Int
}

/// Pure, conservative learning. It never observes pixels or invents game state, and never
/// rotates/scales movement axes. A group must move coherently before its siblings follow.
public enum ControlLayoutLearning {
    public static func adjustments(for group: ControlLayoutGroup,
                                   elements: [ButtonElement]) -> [ControlGroupAdjustment] {
        let members = elements.filter(group.contains)
        let names = members.compactMap(\.bindingName)
        guard members.count >= 3, members.count <= 256, names.count == members.count,
              Set(names).count == names.count else { return [] }
        let aspects = members.flatMap { ($0.transform.hudSamples ?? []).filter {
            $0.isValid && $0.source == .calibrated
        }.map(\.aspectRatio) }.sorted()
        var shapes: [Double] = []
        for aspect in aspects where !shapes.contains(where: { abs(log($0 / aspect)) < 0.002 }) {
            shapes.append(aspect)
        }
        return shapes.compactMap { aspect in
            let offsets: [CGVector] = members.compactMap { element in
                let samples = (element.transform.hudSamples ?? []).filter {
                    $0.isValid && $0.source == .calibrated && abs(log($0.aspectRatio / aspect)) < 0.002
                }
                guard samples.count == 1, let measured = samples.first,
                      let original = element.transform.baselineHUDTransform(at: measured.aspectRatio) else { return nil }
                return CGVector(dx: (measured.xCoord - original.xCoord) * CGFloat(measured.aspectRatio),
                                dy: measured.yCoord - original.yCoord)
            }
            guard offsets.count >= 2 else { return nil }
            func median(_ values: [CGFloat]) -> CGFloat {
                let sorted = values.sorted(), middle = sorted.count / 2
                return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
            }
            let dx = median(offsets.map(\.dx)), dy = median(offsets.map(\.dy))
            // Reject inconsistent edits, including a differently moving HUD member. Do not
            // silently discard an inconvenient measurement to make a correction seem valid.
            guard dx.isFinite, dy.isFinite, hypot(dx, dy) <= 0.15,
                  offsets.allSatisfy({ hypot($0.dx - dx, $0.dy - dy) <= 0.008 }) else { return nil }
            return ControlGroupAdjustment(group: group.name, aspectRatio: aspect,
                horizontalOffset: dx, verticalOffset: dy, measurements: offsets.count)
        }
    }

    static func applying(_ adjustments: [ControlGroupAdjustment], to element: ButtonElement) -> ButtonElement {
        var result = element
        var samples = (element.transform.hudSamples ?? []).filter { $0.source != .learned }
        for adjustment in adjustments {
            let aspect = adjustment.aspectRatio
            // An individually observed position is authoritative, even when it disagrees
            // with a learned group. Generated/reference samples at this shape can be replaced.
            guard !samples.contains(where: {
                $0.isValid && $0.isObserved && abs(log($0.aspectRatio / aspect)) < 0.002
            }), let baseline = element.transform.baselineHUDTransform(at: aspect) else { continue }
            let sample = ControlHUDSample(aspectRatio: aspect,
                xCoord: baseline.xCoord + adjustment.horizontalOffset / CGFloat(aspect),
                yCoord: baseline.yCoord + adjustment.verticalOffset, size: baseline.size, source: .learned)
            // Reject off-canvas results rather than clamping them into a false target.
            guard sample.isValid else { continue }
            samples.removeAll { abs(log($0.aspectRatio / aspect)) < 0.002 }
            samples.append(sample)
        }
        result.transform.hudSamples = samples.isEmpty ? nil : samples.sorted { $0.aspectRatio < $1.aspectRatio }
        return result
    }
}

extension KeymappingData {
    /// Relearn from immutable baselines and genuine editor samples on every map preparation.
    /// Previously learned samples are discarded, so deleting evidence removes its correction.
    public func withLearnedControlLayouts(sourceAspect: Double? = nil) -> KeymappingData {
        let recorded = mulgAspectRatio.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        guard let aspect = recorded ?? sourceAspect, aspect.isFinite, aspect > 0 else { return self }
        var map = self
        func learned(_ buttons: [ButtonElement], _ drags: [ButtonElement], profile: ControlMapProfile?)
            -> (buttons: [ButtonElement], drags: [ButtonElement]) {
            let all = buttons + drags
            let authored = profile?.layoutGroups ?? []
            let ungrouped = all.filter { element in !authored.contains(where: { $0.contains(element) }) }
            let source = all.compactMap { $0.transform.hudBaselines?.first(where: \.isValid)?.aspectRatio }.first ?? aspect
            let inferred = Self.inferredGroups(ungrouped, aspect: source, referenceBased: true)
            let adjustments = (authored + inferred).map { group -> [ControlGroupAdjustment] in
                guard all.filter(group.contains).allSatisfy({ element in
                    authored.filter { $0.contains(element) }.count <= 1
                }) else { return [] }
                return ControlLayoutLearning.adjustments(for: group, elements: all)
            }
            func apply(_ original: ButtonElement) -> ButtonElement {
                var element = original
                element.transform.hudSamples = element.transform.hudSamples?.filter { $0.source != .learned }
                let explicitIndices = authored.indices.filter { authored[$0].contains(element) }
                let indices = explicitIndices.isEmpty
                    ? inferred.indices.filter { inferred[$0].contains(element) }.map { $0 + authored.count }
                    : Array(explicitIndices)
                guard indices.count == 1, let index = indices.first else { return element }
                return ControlLayoutLearning.applying(adjustments[index], to: element)
            }
            return (buttons.map(apply), drags.map(apply))
        }
        let base = learned(map.buttonModels, map.draggableButtonModels, profile: map.mulgControlProfile)
        map.buttonModels = base.buttons
        map.draggableButtonModels = base.drags
        map.mulgLayers = map.mulgLayers?.map { original in
            var layer = original
            let result = learned(layer.buttonModels, layer.draggableButtonModels, profile: layer.mulgControlProfile)
            layer.buttonModels = result.buttons
            layer.draggableButtonModels = result.drags
            return layer
        }
        return map
    }
}
