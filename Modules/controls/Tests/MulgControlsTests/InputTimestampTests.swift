import Darwin
import Testing
@testable import MulgControls

@Suite("Raw mouse timestamps")
struct InputTimestampTests {
    @Test func coalescingKeepsFirstArrivalAndClearsItAfterDelivery() {
        let mouse = RawMouse()
        let before = mach_absolute_time()
        #expect(mouse.add(dx: 2, dy: 3))
        let afterFirst = mach_absolute_time()
        #expect(!mouse.add(dx: 5, dy: 7))
        let sample = mouse.takeSample()
        #expect(sample.movement.dx == 7 && sample.movement.dy == 10)
        #expect(sample.arrival.map { $0 >= before && $0 <= afterFirst } == true)
        #expect(mouse.takeSample().arrival == nil)
        #expect(mouse.add(dx: 1, dy: 1))
        #expect(mouse.takeSample().arrival.map { $0 >= afterFirst } == true)
    }
}
