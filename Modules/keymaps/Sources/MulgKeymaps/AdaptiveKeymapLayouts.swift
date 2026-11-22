import Foundation

/// Derives common window shapes from an immutable source map. These are projections,
/// not a claim to detect the game's HUD. Real samples always retain priority.
extension KeyModelTransform {
    public var hasObservedHUDSamples: Bool {
        (hudSamples ?? []).contains { $0.isValid && ($0.source == nil || $0.source == .published || $0.source == .calibrated) }
    }

    public func withAdaptiveHUDSamples(referenceAspect: Double) -> KeyModelTransform {
        guard referenceAspect.isFinite, referenceAspect > 0 else { return self }
        var result = self
        if result.hudBaselines?.contains(where: { $0.isValid && ($0.isObserved && $0.source != .calibrated || $0.source == .reference) }) != true {
            let originals = (hudSamples ?? []).filter {
                $0.isValid && ($0.isObserved && $0.source != .calibrated || $0.source == .reference)
            }
            if !originals.isEmpty { result.hudBaselines = originals.sorted { $0.aspectRatio < $1.aspectRatio } }
            else if !(hudSamples ?? []).contains(where: { $0.isValid && ($0.source == .calibrated || $0.source == .learned) }) {
                let sample = ControlHUDSample(aspectRatio: referenceAspect, xCoord: xCoord,
                    yCoord: yCoord, size: size, source: .reference)
                if sample.isValid { result.hudBaselines = [sample] }
            }
        }
        // Resolve each anchor once on the source canvas, before another shape moves it.
        let anchored = KeymapCanvas(referenceAspectRatio: referenceAspect, viewportAspectRatio: referenceAspect)?.fitted(self)
        result.horizontalAnchor = horizontalAnchor ?? anchored?.horizontalAnchor
        result.verticalAnchor = verticalAnchor ?? anchored?.verticalAnchor
        var samples = (hudSamples ?? []).filter(\.isValid)
        let original = result
        for aspect in [referenceAspect, 16.0 / 10, 16.0 / 9, 21.0 / 9] {
            guard !samples.contains(where: { abs(log($0.aspectRatio / aspect)) < 0.002 }) else { continue }
            let fitted = original.fitted(from: referenceAspect, to: aspect)
            let sample = ControlHUDSample(aspectRatio: aspect, xCoord: fitted.xCoord,
                yCoord: fitted.yCoord, size: fitted.size,
                source: abs(aspect - referenceAspect) < 0.001 && result.hudBaselines != nil ? .reference : .projected)
            if sample.isValid { samples.append(sample) }
        }
        result.hudSamples = samples.isEmpty ? hudSamples : samples.sorted { $0.aspectRatio < $1.aspectRatio }
        return result
    }
}

extension KeymappingData {
    /// Applies to all control kinds and all layers. Binding codes, calibration, controller
    /// bindings and recorded HUD samples are preserved.
    public func withAdaptiveLayouts(sourceAspect: Double? = nil, unlockWindow: Bool = false) -> KeymappingData {
        let recorded = mulgAspectRatio.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        guard hasTouchControls, let aspect = recorded ?? sourceAspect,
              aspect.isFinite, aspect > 0 else { return self }
        var map = withAdaptiveControlGroups(sourceAspect: aspect)
        map.mulgAspectRatio = aspect
        if unlockWindow { map.mulgLockAspectRatio = false }
        func buttons(_ items: [ButtonElement]) -> [ButtonElement] {
            items.map { var e = $0; e.transform = e.transform.withAdaptiveHUDSamples(referenceAspect: aspect); return e }
        }
        func sticks(_ items: [JoystickElement]) -> [JoystickElement] {
            items.map { var e = $0; e.transform = e.transform.withAdaptiveHUDSamples(referenceAspect: aspect); return e }
        }
        func cameras(_ items: [MouseAreaElement]) -> [MouseAreaElement] {
            items.map { var e = $0; e.transform = e.transform.withAdaptiveHUDSamples(referenceAspect: aspect); return e }
        }
        map.buttonModels = buttons(map.buttonModels)
        map.draggableButtonModels = buttons(map.draggableButtonModels)
        map.joystickModel = sticks(map.joystickModel)
        map.mouseAreaModel = cameras(map.mouseAreaModel)
        map.mulgLayers = map.mulgLayers?.map {
            var layer = $0
            layer.buttonModels = buttons(layer.buttonModels)
            layer.draggableButtonModels = buttons(layer.draggableButtonModels)
            layer.joystickModel = sticks(layer.joystickModel)
            layer.mouseAreaModel = cameras(layer.mouseAreaModel)
            return layer
        }
        return map.withLearnedControlLayouts(sourceAspect: aspect)
    }
}

public enum AdaptiveKeymapImport {
    /// Preserve fields this version does not understand, including nested control fields.
    /// Importing a map is no reason to strip its future metadata.
    public static func prepare(_ data: Data, sourceAspect: Double, bundleIdentifier: String) throws -> Data {
        let decoded = try PropertyListDecoder().decode(KeymappingData.self, from: data)
        guard decoded.isSupportedVersion else {
            throw CocoaError(.coderInvalidValue, userInfo: [NSLocalizedDescriptionKey: "The keymap format is too new."])
        }
        let prepared = decoded.withAdaptiveLayouts(sourceAspect: sourceAspect, unlockWindow: true)
        var raw = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
        let encoded = try PropertyListEncoder().encode(prepared)
        let generated = try PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any] ?? [:]
        func merge(_ original: [String: Any], _ added: [String: Any]) -> [String: Any] {
            var result = original
            for key in ["buttonModels", "draggableButtonModels", "joystickModel", "mouseAreaModel"] {
                guard var controls = original[key] as? [[String: Any]],
                      let projected = added[key] as? [[String: Any]], controls.count == projected.count else { continue }
                for i in controls.indices {
                    guard var transform = controls[i]["transform"] as? [String: Any],
                          let annotations = projected[i]["transform"] as? [String: Any] else { continue }
                    for field in ["hudSamples", "hudBaselines", "horizontalAnchor", "verticalAnchor"] {
                        if ["hudSamples", "hudBaselines"].contains(field),
                           var existing = transform[field] as? [[String: Any]],
                           let samples = annotations[field] as? [[String: Any]] {
                            // Drop stale managed estimates, retain all unknown nested fields.
                            existing.removeAll { original in
                                guard let source = original["source"] as? String,
                                      source == "projected" || source == "learned",
                                      let aspect = original["aspectRatio"] as? Double, aspect > 0 else { return false }
                                return !samples.contains { sample in
                                    guard let recorded = sample["aspectRatio"] as? Double, recorded > 0 else { return false }
                                    return abs(log(recorded / aspect)) < 0.002
                                }
                            }
                            for sample in samples {
                                guard let aspect = sample["aspectRatio"] as? Double, aspect > 0 else { continue }
                                if let index = existing.firstIndex(where: {
                                    guard let recorded = $0["aspectRatio"] as? Double, recorded > 0 else { return false }
                                    return abs(log(recorded / aspect)) < 0.002
                                }) {
                                    for field in ["aspectRatio", "xCoord", "yCoord", "size", "source"] {
                                        if let value = sample[field] { existing[index][field] = value }
                                        else { existing[index].removeValue(forKey: field) }
                                    }
                                } else { existing.append(sample) }
                            }
                            transform[field] = existing
                        } else if let value = annotations[field] { transform[field] = value }
                    }
                    controls[i]["transform"] = transform
                }
                result[key] = controls
            }
            return result
        }
        raw = merge(raw, generated)
        if var layers = raw["mulgLayers"] as? [[String: Any]],
           let projected = generated["mulgLayers"] as? [[String: Any]], layers.count == projected.count {
            for i in layers.indices { layers[i] = merge(layers[i], projected[i]) }
            raw["mulgLayers"] = layers
        }
        if let aspect = prepared.mulgAspectRatio { raw["mulgAspectRatio"] = aspect }
        if prepared.hasTouchControls { raw["mulgLockAspectRatio"] = false }
        raw["bundleIdentifier"] = bundleIdentifier
        return try PropertyListSerialization.data(fromPropertyList: raw, format: .xml, options: 0)
    }
}
