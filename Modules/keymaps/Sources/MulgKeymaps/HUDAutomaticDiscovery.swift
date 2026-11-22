import CoreGraphics
import Foundation

public struct HUDAutomaticCandidate: Sendable {
    public let anchor: ControlHUDAnchor
    public let point: CGPoint
    public let shapeConfidence: Double
}

/// Bootstraps references from mapped HUD regions, not arbitrary world textures. A joystick
/// needs a visible closed ring. Buttons can also use an isolated bright HUD glyph. Initial
/// discovery stays inside the map's target neighborhood and never assigns a new input.
public enum HUDAutomaticDiscovery {
    private struct Plane {
        let width: Int; let height: Int; let bytes: [UInt8]
        init(_ image: HUDGrayImage) { width = image.width; height = image.height; bytes = Array(image.pixels) }
        func at(_ x: Double, _ y: Double) -> Double {
            let ix = min(width - 2, max(0, Int(x))), iy = min(height - 2, max(0, Int(y)))
            let fx = min(1, max(0, x - Double(ix))), fy = min(1, max(0, y - Double(iy)))
            let i = iy * width + ix
            return (Double(bytes[i]) * (1 - fx) + Double(bytes[i + 1]) * fx) * (1 - fy)
                + (Double(bytes[i + width]) * (1 - fx) + Double(bytes[i + width + 1]) * fx) * fy
        }
    }

    public static func discover(in image: HUDGrayImage, targets: [HUDControlTarget],
                                aspect: Double, maximumTargets: Int = 8) -> [HUDAutomaticCandidate] {
        guard image.isValid, image.width > 4, image.height > 4, aspect.isFinite, aspect > 0 else { return [] }
        let plane = Plane(image), h = Double(image.height), w = Double(image.width)
        let stretch = w / h / aspect
        guard (0.4...2.5).contains(stretch) else { return [] }
        var found: [HUDAutomaticCandidate] = []
        for target in targets.prefix(min(16, max(1, maximumTargets))) {
            if Task.isCancelled { break }
            guard target.transform.xCoord.isFinite, target.transform.yCoord.isFinite,
                  (0...1).contains(target.transform.xCoord), (0...1).contains(target.transform.yCoord),
                  target.transform.size.isFinite, target.transform.size > 0 else { continue }
            let isStick = target.address.kind == .digitalJoystick || target.address.kind == .analogJoystick
            let nominal = min(h * (isStick ? 0.55 : 0.24), max(h * 0.035, Double(target.transform.size) / 100 * max(1, aspect) * h))
            let ex = Double(target.transform.xCoord) * w, ey = Double(target.transform.yCoord) * h
            let neighborhood = min(h * 0.045, max(5, nominal * (isStick ? 0.18 : 0.3)))
            var circles: [(score: Double, x: Double, y: Double, radius: Double)] = []
            let radii = isStick ? [0.20, 0.25, 0.32] : [0.3, 0.4, 0.5]
            for factor in radii {
                let radius = max(7, nominal * factor)
                for y in stride(from: ey - neighborhood, through: ey + neighborhood, by: 3) {
                    for x in stride(from: ex - neighborhood * stretch, through: ex + neighborhood * stretch, by: 3) {
                        guard x - radius * stretch > 2, x + radius * stretch < w - 2,
                              y - radius > 2, y + radius < h - 2,
                              hypot((x - ex) / stretch, y - ey) <= radius * 0.65 else { continue }
                        var count = 0, contrast = 0.0
                        for bin in 0..<32 {
                            let angle = Double(bin) * .pi / 16, dx = cos(angle) * stretch, dy = sin(angle)
                            let value = plane.at(x + dx * radius, y + dy * radius)
                            let inner = plane.at(x + dx * (radius - 2), y + dy * (radius - 2))
                            let outer = plane.at(x + dx * (radius + 2), y + dy * (radius + 2))
                            let peak = value - (inner + outer) / 2
                            if peak >= 8 || abs(inner - outer) >= 25 {
                                count += 1; contrast += min(1, max(peak, abs(inner - outer) / 2) / 30)
                            }
                        }
                        if count >= 25 {
                            let score = Double(count) / 32 * 0.65 + contrast / 32 * 0.35
                            if score >= 0.79 { circles.append((score, x, y, radius)) }
                        }
                    }
                }
            }
            if let circle = circles.max(by: { $0.score < $1.score }) {
                let other = circles.filter { hypot(($0.x - circle.x) / stretch, $0.y - circle.y) > max(6, circle.radius * 0.6) }
                    .map(\.score).max() ?? 0
                if circle.score - other >= 0.055 {
                    let span = min(0.42, max(0.04, circle.radius * max(1, stretch) * 2.65 / h))
                    let point = CGPoint(x: circle.x / w, y: circle.y / h)
                    if let candidate = reference(in: image, target: target, point: point, span: span,
                        aspect: aspect, ringRadius: circle.radius / (span * h) * 24, stretch: stretch, score: circle.score) {
                        found.append(candidate); continue
                    }
                }
            }
            // A non-circular button must expose an isolated bright glyph at the map's own
            // position. No relocation is inferred from an unrecognized rectangular/world patch.
            guard !isStick else { continue }
            let span = min(0.16, max(0.05, nominal * 1.2 / h))
            let point = CGPoint(x: target.transform.xCoord, y: target.transform.yCoord)
            if let candidate = reference(in: image, target: target, point: point, span: span,
                aspect: aspect, ringRadius: nil, stretch: stretch, score: 0.8) { found.append(candidate) }
        }
        return found
    }

    private static func reference(in image: HUDGrayImage, target: HUDControlTarget, point: CGPoint,
                                  span: Double, aspect: Double, ringRadius: Double?, stretch: Double,
                                  score: Double) -> HUDAutomaticCandidate? {
        guard let patch = HUDAnchorMatcher.template(in: image, center: point, spanInHeights: span) else { return nil }
        let pixels = Array(patch.pixels)
        var mask = [UInt8](repeating: 0, count: 576), bright = 0, border = 0
        var minX = 24, minY = 24, maxX = 0, maxY = 0
        let isStick = target.address.kind == .digitalJoystick || target.address.kind == .analogJoystick
        for y in 1..<23 { for x in 1..<23 {
            let radius = hypot((Double(x) - 11.5) / stretch, Double(y) - 11.5)
            let value = pixels[y * 24 + x]
            if value >= 195 && !isStick {
                if x < 4 || x > 19 || y < 4 || y > 19 { border += 1 }
                else {
                    bright += 1; minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                    mask[y * 24 + x] = 255
                    // Gradients around the glyph survive changing world pixels better than
                    // a complete rectangular screenshot patch.
                    for yy in (y - 1)...(y + 1) { for xx in (x - 1)...(x + 1) { mask[yy * 24 + xx] = 255 } }
                }
            }
            if let ringRadius, abs(radius - ringRadius) <= 2.3 { mask[y * 24 + x] = 255 }
        } }
        if ringRadius == nil {
            guard bright >= 18, bright <= 180, border <= 18,
                  minX <= 9, maxX >= 14, minY <= 9, maxY >= 14 else { return nil }
        }
        let anchor = ControlHUDAnchor(address: target.address, bindingSignature: target.bindingSignature,
            referenceAspect: aspect, patchInHeights: span, image: patch, featureMask: Data(mask),
            captureAspect: Double(image.width) / Double(image.height))
        return HUDAutomaticCandidate(anchor: anchor, point: point, shapeConfidence: score)
    }
}
