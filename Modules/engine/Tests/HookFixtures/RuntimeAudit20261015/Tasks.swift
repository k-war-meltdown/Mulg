import Foundation
@MainActor enum WaitClock {
    static var active = 0
    static func sleep(_ duration: Duration) async throws {
        active += 1; defer { active -= 1 }
        try await Task.sleep(for: .seconds(20))
    }
}
// __PRODUCTION__
Task { @MainActor in
    let ticker = FrameTicker(), begins = TouchBeginWaiters()
    let frame = Task { await ticker.wait(frames: 1, timeout: .seconds(20)) }
    let touch = Task { await begins.wait(7, timeout: .seconds(20)) }
    while WaitClock.active < 2 { await Task.yield() }
    ticker.tick(); begins.resolve(7, delivered: true)
    await frame.value; let delivered = await touch.value; assert(delivered)
    for _ in 0..<100 where WaitClock.active != 0 { await Task.yield() }
    assert(WaitClock.active == 0, "Completed waits must cancel their still-sleeping timeout tasks")
    let cancelled = Task { await ticker.wait(frames: 10, timeout: .seconds(20)) }
    while WaitClock.active == 0 { await Task.yield() }
    cancelled.cancel(); await cancelled.value
    for _ in 0..<100 where WaitClock.active != 0 { await Task.yield() }
    assert(WaitClock.active == 0 && ticker.pendingWaiters == 0)
    print("PASS: completed and cancelled frame/touch waits release their timeout tasks")
    exit(0)
}
dispatchMain()
