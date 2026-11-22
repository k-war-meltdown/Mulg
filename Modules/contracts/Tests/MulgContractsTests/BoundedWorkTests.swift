import MulgContracts
import Testing

private actor WorkCounts {
    var active = 0
    var peak = 0
    var started = 0
    func enter() { active += 1; started += 1; peak = max(peak, active) }
    func leave() { active -= 1 }
}

@Suite("Bounded install work")
struct BoundedWorkTests {
    @Test func boundsConcurrencyAndProcessesEveryItem() async throws {
        let counts = WorkCounts()
        try await BoundedWork.run(Array(0..<20), limit: 2) { _ in
            await counts.enter()
            try await Task.sleep(for: .milliseconds(5))
            await counts.leave()
        }
        #expect(await counts.peak == 2)
        #expect(await counts.started == 20)
        #expect(await counts.active == 0)
    }

    @Test func failureStopsAdmission() async {
        enum Failure: Error { case rejected }
        let counts = WorkCounts()
        await #expect(throws: Failure.self) {
            try await BoundedWork.run(Array(0..<100), limit: 4) { item in
                await counts.enter()
                if item == 0 { throw Failure.rejected }
                try await Task.sleep(for: .seconds(1))
            }
        }
        #expect(await counts.started <= 4)
    }

    @Test func cancellationStopsAdmission() async {
        let counts = WorkCounts()
        let job = Task {
            try await BoundedWork.run(Array(0..<100), limit: 2) { _ in
                await counts.enter()
                try await Task.sleep(for: .seconds(10))
            }
        }
        while await counts.started < 2 { await Task.yield() }
        job.cancel()
        await #expect(throws: CancellationError.self) { try await job.value }
        #expect(await counts.started == 2)
    }
}
