import CoreGraphics
import Foundation
import Testing
import MulgContracts
import MulgKeymaps
@testable import MulgControls

@Suite("Pinch zoom (scroll wheel and Camera reach)") @MainActor
struct PinchZoomTests {
    private func pinch(_ injector: RecordingInjector) -> PinchZoom {
        PinchZoom(injector: injector) { ScreenMetrics(bounds: injector.screenBounds) }
    }

    private func count(_ injector: RecordingInjector, _ phase: TouchPhase) -> Int {
        injector.events.filter { $0.phase == phase }.count
    }

    @Test("Scrolling pinches two fingers side by side at the centre and lifts them after a pause")
    func scrollLiftsAfterPause() async throws {
        let injector = RecordingInjector()
        let zoom = pinch(injector)
        zoom.scroll(10)
        zoom.scroll(10)
        #expect(zoom.isActive)
        let began = injector.events.filter { $0.phase == .began }
        let ys: [CGFloat] = began.map { $0.point.y }
        let xs: [CGFloat] = began.map { $0.point.x }.sorted()
        let expected: [CGFloat] = [180, 820] // centre 500, 0.32 of the width either side
        #expect(ys == [250, 250])
        #expect(xs == expected)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!zoom.isActive)
        #expect(count(injector, .ended) == 2)
    }

    @Test("Spreading (zoom in) also ends: at the end of its travel")
    func spreadingEnds() {
        let injector = RecordingInjector()
        let zoom = pinch(injector)
        for _ in 0..<40 { zoom.scroll(-10) } // 50 to 320 points: reaches the end and lifts
        #expect(count(injector, .ended) >= 2)
        #expect(count(injector, .began) >= 2)
    }

    @Test("A sweep is whole pinches, each lifted, in the asked direction")
    func sweep() async {
        let injector = RecordingInjector()
        let zoom = pinch(injector)
        await zoom.sweep(outward: true, gestures: 2)
        #expect(!zoom.isActive)
        #expect(count(injector, .began) == 4)
        #expect(count(injector, .ended) == 4)
        // Outward: the fingers move towards each other.
        let first = injector.events.filter { $0.id == 0 }
        let start: CGFloat = abs(first[0].point.x - 500)
        let end: CGFloat = abs(first[first.count - 1].point.x - 500)
        #expect(start > end)
    }
}
