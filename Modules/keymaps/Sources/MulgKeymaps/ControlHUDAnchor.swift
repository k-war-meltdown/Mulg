import CoreGraphics
import Foundation

/// A small, locally stored HUD patch, learned automatically or explicitly confirmed.
/// Binding identity is checked against the map on every load; images never create inputs.
public struct ControlHUDAnchor: Codable, Sendable, Equatable, Identifiable {
    public static let maximumCount = 48
    public let id: UUID
    public let address: ControlBindingAddress
    public let bindingSignature: String
    public let referenceAspect: Double
    /// Actual captured surface shape, which can differ from the renderer's logical shape.
    /// Older references omit this and retain their original isotropic matching behavior.
    public let captureAspect: Double?
    public let patchInHeights: Double
    public let image: HUDGrayImage
    /// Automatic references can ignore world pixels outside a detected HUD outline/glyph.
    public let featureMask: Data?
    public let schema: Int

    public init(address: ControlBindingAddress, bindingSignature: String, referenceAspect: Double,
                patchInHeights: Double, image: HUDGrayImage, featureMask: Data? = nil,
                captureAspect: Double? = nil) {
        id = UUID(); self.address = address; self.bindingSignature = bindingSignature
        self.referenceAspect = referenceAspect; self.patchInHeights = patchInHeights
        self.image = image; schema = 1
        self.featureMask = featureMask
        self.captureAspect = captureAspect
    }
    public var isValid: Bool {
        schema == 1 && address.layer >= 0 && address.index >= 0 && address.kind != .camera
            && !bindingSignature.isEmpty && bindingSignature.count <= 2048
            && referenceAspect.isFinite && (0.3...6).contains(referenceAspect)
            && (captureAspect.map { $0.isFinite && (0.1...12).contains($0) } ?? true)
            && patchInHeights.isFinite && (0.025...0.45).contains(patchInHeights)
            && image.isValid && image.width == 24 && image.height == 24
            && (featureMask == nil || featureMask?.count == 576)
    }
}

/// Explicit top-left-origin grayscale pixels. No framework image objects cross the matcher task.
public struct HUDGrayImage: Codable, Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let pixels: Data
    public init(width: Int, height: Int, pixels: Data) {
        self.width = width; self.height = height; self.pixels = pixels
    }
    public var isValid: Bool {
        (1...4096).contains(width) && (1...2048).contains(height) && pixels.count == width * height
    }
}

public struct HUDControlTarget: Sendable {
    public let address: ControlBindingAddress
    public let bindingSignature: String
    public let transform: KeyModelTransform
    public init(address: ControlBindingAddress, bindingSignature: String, transform: KeyModelTransform) {
        self.address = address; self.bindingSignature = bindingSignature; self.transform = transform
    }
}

extension KeymappingData {
    /// Uses the existing binding graph, including arbitrary keys, analog sticks and layers.
    public func hudTarget(at address: ControlBindingAddress, aspect: Double) -> HUDControlTarget? {
        guard address.layer >= 0, address.index >= 0, aspect.isFinite, aspect > 0 else { return nil }
        let buttons: [ButtonElement], drags: [ButtonElement], sticks: [JoystickElement]
        var hold = "base"
        if address.layer == 0 {
            buttons = buttonModels; drags = draggableButtonModels; sticks = joystickModel
        } else {
            guard let layers = mulgLayers, layers.indices.contains(address.layer - 1),
                  layers[address.layer - 1].hasHoldKey else { return nil }
            let layer = layers[address.layer - 1]
            buttons = layer.buttonModels; drags = layer.draggableButtonModels; sticks = layer.joystickModel
            hold = layer.holdKeyName
        }
        let transform: KeyModelTransform
        var semantics = ""
        switch address.kind {
        case .button:
            guard buttons.indices.contains(address.index) else { return nil }
            let element = buttons[address.index]
            transform = element.transform.fitted(from: mulgAspectRatio ?? aspect, to: aspect)
            semantics = "\(element.toggle ?? false):\(element.tapDurationMilliseconds ?? 0)"
        case .draggable:
            guard drags.indices.contains(address.index) else { return nil }
            let element = drags[address.index]
            transform = element.transform.fitted(from: mulgAspectRatio ?? aspect, to: aspect)
            semantics = element.dragMotionBindingName
        case .digitalJoystick, .analogJoystick:
            guard sticks.indices.contains(address.index) else { return nil }
            let element = sticks[address.index]
            guard element.isAnalog == (address.kind == .analogJoystick) else { return nil }
            transform = element.calibratedTransform(forAspect: aspect)
                ?? element.transform.fitted(from: mulgAspectRatio ?? aspect, to: aspect)
            semantics = "\(element.effectiveMode.rawValue)"
        case .camera: return nil // World imagery is not a stable HUD target.
        }
        let bindings = ControlBindingGraph(self).bindings.filter { $0.address == address }
        guard !bindings.isEmpty, transform.xCoord.isFinite, transform.yCoord.isFinite,
              (0...1).contains(transform.xCoord), (0...1).contains(transform.yCoord),
              transform.size.isFinite, transform.size > 0 else { return nil }
        let names = bindings.map { "\($0.channel.rawValue):\($0.part ?? ""):\($0.key)" }.joined(separator: "|")
        return HUDControlTarget(address: address,
            bindingSignature: "\(hold)|\(address.kind.rawValue)|\(names)|\(semantics)", transform: transform)
    }

    public var validHUDAnchors: [ControlHUDAnchor] {
        var seen: Set<ControlBindingAddress> = []
        return Array((mulgHUDAnchors ?? []).filter { anchor in
            guard anchor.isValid, !seen.contains(anchor.address),
                  hudTarget(at: anchor.address, aspect: anchor.referenceAspect)?.bindingSignature == anchor.bindingSignature else { return false }
            seen.insert(anchor.address); return true
        }.prefix(ControlHUDAnchor.maximumCount))
    }
}

public struct HUDAnchorMatch: Sendable {
    public let point: CGPoint // Fractions of the current visible game surface.
    public let confidence: Double
    public let margin: Double
    public var isConfident: Bool { confidence >= 0.9 && margin >= 0.055 }
}

/// Conservative local template matching. No game names, trained model, inferred inputs,
/// global search or writeback of automatic guesses. Ambiguous repeated icons are rejected.
public enum HUDAnchorMatcher {
    private struct Plane {
        let image: HUDGrayImage
        let pixels: [UInt8]
        init(_ image: HUDGrayImage) { self.image = image; pixels = Array(image.pixels) }
        func sample(_ x: Double, _ y: Double) -> Double {
            let ix = min(image.width - 2, max(0, Int(x))), iy = min(image.height - 2, max(0, Int(y)))
            let fx = min(1, max(0, x - Double(ix))), fy = min(1, max(0, y - Double(iy)))
            let i = iy * image.width + ix
            return (Double(pixels[i]) * (1 - fx) + Double(pixels[i + 1]) * fx) * (1 - fy)
                + (Double(pixels[i + image.width]) * (1 - fx) + Double(pixels[i + image.width + 1]) * fx) * fy
        }
    }

    public static func template(in image: HUDGrayImage, center: CGPoint, spanInHeights: Double) -> HUDGrayImage? {
        guard image.isValid, image.width > 2, image.height > 2, center.x.isFinite, center.y.isFinite,
              spanInHeights.isFinite, (0.025...0.45).contains(spanInHeights) else { return nil }
        let plane = Plane(image), span = spanInHeights * Double(image.height)
        let cx = Double(center.x) * Double(image.width), cy = Double(center.y) * Double(image.height)
        guard cx - span / 2 >= 1, cy - span / 2 >= 1,
              cx + span / 2 < Double(image.width - 1), cy + span / 2 < Double(image.height - 1) else { return nil }
        var bytes = Data(capacity: 576)
        for y in 0..<24 { for x in 0..<24 {
            bytes.append(UInt8(min(255, max(0, plane.sample(cx + (Double(x) - 11.5) * span / 24,
                                                         cy + (Double(y) - 11.5) * span / 24)))))
        } }
        let patch = HUDGrayImage(width: 24, height: 24, pixels: bytes)
        return features(Plane(patch)).count >= 36 ? patch : nil
    }

    private struct Feature { let x: Double; let y: Double; let value: Double; let dx: Double; let dy: Double }
    private static func features(_ plane: Plane, mask: Data? = nil) -> [Feature] {
        var ranked: [(Double, Feature)] = []
        let allowed = mask.map { Array($0) }
        // Keep separated samples; pure flat patches cannot become references.
        for y in stride(from: 2, to: 22, by: mask == nil ? 2 : 1) { for x in stride(from: 2, to: 22, by: mask == nil ? 2 : 1) {
            if let allowed, allowed[y * 24 + x] == 0 { continue }
            let px = Double(x), py = Double(y)
            let dx = plane.sample(px + 1, py) - plane.sample(px - 1, py)
            let dy = plane.sample(px, py + 1) - plane.sample(px, py - 1)
            let energy = dx * dx + dy * dy
            if energy >= 64 { ranked.append((energy, Feature(x: px - 11.5, y: py - 11.5,
                value: plane.sample(px, py), dx: dx, dy: dy))) }
        } }
        return ranked.sorted { $0.0 > $1.0 }.prefix(72).map(\.1)
    }

    public static func match(_ anchor: ControlHUDAnchor, in image: HUDGrayImage,
                             expected: CGPoint, scaleInHeights: Double,
                             searchRadiusInHeights: Double = 0.145,
                             viewportAspect: Double? = nil,
                             searchBounds: CGRect? = nil) -> HUDAnchorMatch? {
        guard anchor.isValid, image.isValid, image.width > 2, image.height > 2,
              expected.x.isFinite, expected.y.isFinite, scaleInHeights.isFinite,
              (0...1).contains(expected.x), (0...1).contains(expected.y),
              (0.15...3).contains(scaleInHeights), searchRadiusInHeights.isFinite,
              (0.02...0.2).contains(searchRadiusInHeights) else { return nil }
        let plane = Plane(image), points = features(Plane(anchor.image), mask: anchor.featureMask)
        guard points.count >= 36 else { return nil }
        let h = Double(image.height), w = Double(image.width)
        var horizontalStretch = 1.0
        if let captured = anchor.captureAspect, let viewportAspect {
            guard viewportAspect.isFinite, viewportAspect > 0 else { return nil }
            horizontalStretch = (w / h / viewportAspect) / (captured / anchor.referenceAspect)
            guard horizontalStretch.isFinite, (0.25...4).contains(horizontalStretch) else { return nil }
        }
        let span = anchor.patchInHeights * h * scaleInHeights
        let ex = Double(expected.x) * w, ey = Double(expected.y) * h
        let radius = min(112, max(16, h * searchRadiusInHeights))
        let region: CGRect
        if let searchBounds {
            guard searchBounds.minX.isFinite, searchBounds.minY.isFinite,
                  searchBounds.width.isFinite, searchBounds.height.isFinite,
                  searchBounds.width > 0, searchBounds.height > 0 else { return nil }
            region = searchBounds.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !region.isNull, region.width * region.height <= 0.28 else { return nil }
        } else {
            region = CGRect(x: max(1, ex - radius * horizontalStretch) / w, y: max(1, ey - radius) / h,
                width: (min(w - 2, ex + radius * horizontalStretch) - max(1, ex - radius * horizontalStretch)) / w,
                height: (min(h - 2, ey + radius) - max(1, ey - radius)) / h)
        }
        let scanStep = searchBounds == nil ? 4.0 : 8.0
        let mean = points.reduce(0) { $0 + $1.value } / Double(points.count)
        let variance = points.reduce(0) { $0 + pow($1.value - mean, 2) }
        let edgeEnergy = points.reduce(0) { $0 + $1.dx * $1.dx + $1.dy * $1.dy }
        guard variance > 100, edgeEnergy > 100 else { return nil }
        func score(_ x: Double, _ y: Double, _ size: Double) -> Double {
            let step = size / 24, stepX = step * horizontalStretch
            guard x - size * horizontalStretch / 2 >= 1, y - size / 2 >= 1,
                  x + size * horizontalStretch / 2 < w - 1, y + size / 2 < h - 1 else { return -1 }
            var sum = 0.0, square = 0.0, correlation = 0.0, edge = 0.0, energy = 0.0
            for f in points {
                let px = x + f.x * stepX, py = y + f.y * step
                let value = plane.sample(px, py)
                let dx = plane.sample(px + stepX, py) - plane.sample(px - stepX, py)
                let dy = plane.sample(px, py + step) - plane.sample(px, py - step)
                sum += value; square += value * value; correlation += (f.value - mean) * value
                edge += f.dx * dx + f.dy * dy; energy += dx * dx + dy * dy
            }
            let v = max(0, square - sum * sum / Double(points.count))
            guard v > 100, energy > 100 else { return -1 }
            return 0.35 * correlation / sqrt(variance * v) + 0.65 * edge / sqrt(edgeEnergy * energy)
        }
        var candidates: [(score: Double, x: Double, y: Double, size: Double)] = []
        for factor in [0.85, 1.0, 1.15] {
            if Task.isCancelled { return nil }
            let size = span * factor
            for y in stride(from: max(1, Double(region.minY) * h), through: min(h - 2, Double(region.maxY) * h), by: scanStep) {
                if Task.isCancelled { return nil }
                for x in stride(from: max(1, Double(region.minX) * w), through: min(w - 2, Double(region.maxX) * w), by: scanStep * horizontalStretch) {
                    let value = score(x, y, size)
                    if value > 0.6 { candidates.append((value, x, y, size)) }
                }
            }
        }
        guard var best = candidates.max(by: { $0.score < $1.score }) else { return nil }
        for y in stride(from: best.y - scanStep, through: best.y + scanStep, by: 1) {
            if Task.isCancelled { return nil }
            for x in stride(from: best.x - scanStep * horizontalStretch,
                            through: best.x + scanStep * horizontalStretch, by: horizontalStretch) {
                let value = score(x, y, best.size)
                if value > best.score { best = (value, x, y, best.size) }
            }
        }
        // Coarse regional search must refine competing peaks too; otherwise a unique
        // fine match could conceal an equally good repeated icon elsewhere in the group.
        if searchBounds != nil {
            let peaks = candidates.sorted { $0.score > $1.score }.prefix(24)
            for peak in peaks where hypot((peak.x - best.x) / horizontalStretch, peak.y - best.y) > best.size * 0.35 {
                if Task.isCancelled { return nil }
                for y in stride(from: peak.y - scanStep, through: peak.y + scanStep, by: 2) {
                    for x in stride(from: peak.x - scanStep * horizontalStretch,
                                    through: peak.x + scanStep * horizontalStretch, by: 2 * horizontalStretch) {
                        let value = score(x, y, peak.size)
                        if value > 0.6 { candidates.append((value, x, y, peak.size)) }
                        if value > best.score { best = (value, x, y, peak.size) }
                    }
                }
            }
        }
        let exclusion = max(8, best.size * 0.35)
        let second = candidates.filter { hypot(($0.x - best.x) / horizontalStretch, $0.y - best.y) > exclusion }.map(\.score).max() ?? 0
        return HUDAnchorMatch(point: CGPoint(x: best.x / w, y: best.y / h),
            confidence: best.score, margin: best.score - second)
    }
}
