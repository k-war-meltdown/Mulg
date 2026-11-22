import Testing
@testable import MulgEngine

@Suite("Stable gameplay surface")
struct ViewportSelectionTests {
    @Test func overlaysAndSmallSizeDifferencesDoNotReleaseControls() {
        #expect(ViewportSelection.keepsCurrent(coverage: 1, focused: true, bestCoverage: 0.1, bestFocused: true))
        #expect(ViewportSelection.keepsCurrent(coverage: 0.9, focused: true, bestCoverage: 1, bestFocused: true))
        #expect(!ViewportSelection.keepsCurrent(coverage: 0.1, focused: true, bestCoverage: 1, bestFocused: true))
        #expect(!ViewportSelection.keepsCurrent(coverage: 1, focused: false, bestCoverage: 0.3, bestFocused: true))
    }
}

import QuartzCore

@Suite("Rendered layer geometry")
struct ViewportGeometryTests {
    @Test func insetLayerUsesItsBoundsAndAncestorClipping() {
        let window = CALayer(), owner = CALayer(), render = CALayer()
        window.bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        owner.frame = window.bounds; window.addSublayer(owner)
        render.frame = CGRect(x: 100, y: 100, width: 200, height: 150); owner.addSublayer(render)
        #expect(ViewportGeometry.visibleRect(of: render, in: window) == render.frame)
        #expect(ViewportGeometry.contains(CGPoint(x: 150, y: 130), layer: render, window: window))
        #expect(!ViewportGeometry.contains(CGPoint(x: 50, y: 50), layer: render, window: window))
        owner.bounds = CGRect(x: 0, y: 0, width: 200, height: 150)
        owner.position = CGPoint(x: 100, y: 75); owner.masksToBounds = true
        #expect(ViewportGeometry.visibleRect(of: render, in: window) == CGRect(x: 100, y: 100, width: 100, height: 50))
        owner.isHidden = true
        #expect(ViewportGeometry.visibleRect(of: render, in: window).isNull)
    }
    @Test func transformedSurfaceHitTestingUsesLocalCoordinates() {
        let window = CALayer(), render = CALayer()
        window.bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        render.bounds = CGRect(x: 10, y: 20, width: 200, height: 100)
        render.position = CGPoint(x: 400, y: 300); window.addSublayer(render)
        render.setAffineTransform(CGAffineTransform(rotationAngle: .pi / 4))
        let center = render.convert(CGPoint(x: 110, y: 70), to: window)
        #expect(ViewportGeometry.contains(center, layer: render, window: window))
        let outside = render.convert(CGPoint(x: 9, y: 19), to: window)
        #expect(!ViewportGeometry.contains(outside, layer: render, window: window))
        render.removeFromSuperlayer()
        #expect(ViewportGeometry.visibleRect(of: render, in: window).isNull)
    }
}
