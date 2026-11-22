import CoreGraphics
import Foundation

extension KeymappingData {
    /// A row/column is anchored as a unit before creating projected aspect layouts.
    /// Explicit anchors, measured samples and joystick calibrations remain authoritative.
    public func withAdaptiveControlGroups(sourceAspect: Double? = nil) -> KeymappingData {
        let recorded = mulgAspectRatio.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        guard let aspect = recorded ?? sourceAspect, aspect.isFinite, aspect > 0 else { return self }
        var map = self
        func grouped(_ buttons: [ButtonElement], _ drags: [ButtonElement], profile: ControlMapProfile?)
            -> (buttons: [ButtonElement], drags: [ButtonElement]) {
            let all = buttons + drags
            let explicit = profile?.layoutGroups ?? []
            let inferred = Self.inferredGroups(all, aspect: aspect)
            func apply(_ input: ButtonElement) -> ButtonElement {
                var e = input
                guard !e.transform.hasObservedHUDSamples else { return e }
                let authored = explicit.filter { $0.contains(e) }
                let guessed = inferred.filter { $0.contains(e) }
                // Conflicting group membership is ambiguous: leave the user's map alone.
                let groups = authored.isEmpty ? guessed : authored
                guard groups.count == 1, let group = groups.first else { return e }
                let old = e.transform
                if e.transform.horizontalAnchor == nil { e.transform.horizontalAnchor = group.horizontalAnchor }
                if e.transform.verticalAnchor == nil { e.transform.verticalAnchor = group.verticalAnchor }
                if e.transform != old {
                    // Projections generated from the old independent anchors must not pin
                    // the new group. Original reference samples and observations stay.
                    e.transform.hudSamples = e.transform.hudSamples?.filter { $0.source != .projected }
                }
                return e
            }
            return (buttons.map(apply), drags.map(apply))
        }
        let base = grouped(map.buttonModels, map.draggableButtonModels, profile: map.mulgControlProfile)
        map.buttonModels = base.buttons
        map.draggableButtonModels = base.drags
        map.mulgLayers = map.mulgLayers?.map { original in
            var layer = original
            let result = grouped(layer.buttonModels, layer.draggableButtonModels, profile: layer.mulgControlProfile)
            layer.buttonModels = result.buttons
            layer.draggableButtonModels = result.drags
            return layer
        }
        return map
    }

    /// Conservative spatial inference only: at least three distinct nearby keys in an
    /// edge row/column. No inferred group changes explicit anchors or measured positions.
    static func inferredGroups(_ input: [ButtonElement], aspect: Double,
                               referenceBased: Bool = false) -> [ControlLayoutGroup] {
        guard input.count >= 3, input.count <= 256 else { return [] }
        let eligible = input.compactMap { original -> ButtonElement? in
            var element = original
            if referenceBased {
                guard let baseline = original.transform.baselineHUDTransform(at: aspect) else { return nil }
                element.transform = baseline
            } else {
                guard !element.transform.hasObservedHUDSamples,
                      element.transform.horizontalAnchor == nil, element.transform.verticalAnchor == nil else { return nil }
            }
            let t = element.transform
            guard element.bindingName != nil, t.xCoord.isFinite, t.yCoord.isFinite,
                  (0...1).contains(t.xCoord), (0...1).contains(t.yCoord) else { return nil }
            return element
        }
        var claimed: Set<String> = []
        var groups: [ControlLayoutGroup] = []
        for seed in eligible {
            guard let name = seed.bindingName, !claimed.contains(name) else { continue }
            let x = seed.transform.xCoord, y = seed.transform.yCoord
            let remaining = eligible.filter { $0.bindingName.map { !claimed.contains($0) } ?? false }
            let column = remaining.filter {
                abs($0.transform.xCoord - x) * CGFloat(aspect) <= 0.035 && abs($0.transform.yCoord - y) <= 0.42
            }
            let row = remaining.filter {
                abs($0.transform.yCoord - y) <= 0.02 && abs($0.transform.xCoord - x) * CGFloat(aspect) <= 0.5
            }
            let candidates = (x < 0.25 || x > 0.75) && column.count >= 3 ? column
                : (y < 0.25 || y > 0.75) && row.count >= 3 ? row : []
            let names = Set(candidates.compactMap(\.bindingName))
            guard names.count >= 3, names.count == candidates.count else { continue }
            let centerX = candidates.map { $0.transform.xCoord }.reduce(0, +) / CGFloat(candidates.count)
            let centerY = candidates.map { $0.transform.yCoord }.reduce(0, +) / CGFloat(candidates.count)
            let h: KeymapHorizontalAnchor = centerX < 0.3 ? .left : centerX > 0.7 ? .right : .center
            let v: KeymapVerticalAnchor = centerY < 0.5 ? .top : .bottom
            groups.append(ControlLayoutGroup(name: "inferred row/column", bindingNames: names.sorted(),
                horizontalAnchor: h, verticalAnchor: v))
            claimed.formUnion(names)
        }
        return groups
    }
}
