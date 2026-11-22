import Foundation
import MulgContracts
import MulgEngineHooks
import Testing

@Suite("Frame-start input delivery", .serialized)
struct FrameInputTests {
    @Test("Display links ticking in the same refresh deliver input once; the next refresh delivers again")
    @MainActor
    func oncePerRefresh() {
        var deliveries = 0
        mulg_engine_set_frame_start_handler { deliveries += 1 }
        defer { mulg_engine_set_frame_start_handler(nil) }
        Thread.sleep(forTimeInterval: 0.005)
        for _ in 0..<3 { _ = mulg_engine_display_link_callback(false) {} }  // the game's link, UIKit's, MetalKit's
        #expect(deliveries == 1)
        Thread.sleep(forTimeInterval: 0.005)
        _ = mulg_engine_display_link_callback(false) {}
        #expect(deliveries == 2)
    }
}

@Suite("Frame-critical game threads")
struct ThreadPriorityTests {
    @Test("Render and per-frame worker threads are recognised by name; loading threads are not")
    func roles() {
        let render = ["UnityGfxDeviceWorker", "UnityMultiRenderingThread", "RenderThread 1", "RHIThread", "RHISubmissionThread"]
        let workers = ["Job.Worker 0", "Job.Worker 13", "TaskGraphThreadHP 2", "TaskGraphThreadNP 0", "Foreground Worker #1"]
        let others = ["Background Job.Worker 3", "Background Worker #0", "TaskGraphThreadBP 1", "Loading.AsyncRead",
                      "Loading.PreloadManager", "UnityMain", "com.apple.main-thread", "AudioMixer", ""]
        for name in render { #expect(mulg_engine_thread_role(name) == .render, "\(name)") }
        for name in workers { #expect(mulg_engine_thread_role(name) == .worker, "\(name)") }
        for name in others { #expect(mulg_engine_thread_role(name) == .none, "\(name)") }
        #expect(mulg_engine_thread_role(nil) == .none)
    }

    @Test("Workers are raised only up to the fast cores left after the main and render threads")
    func workerBudget() {
        #expect(mulg_engine_worker_budget(6) == 4) // M6: 2 Super + 4 Performance
        #expect(mulg_engine_worker_budget(4) == 2)
        #expect(mulg_engine_worker_budget(2) == 0 && mulg_engine_worker_budget(1) == 0)
        #expect(mulg_engine_worker_budget(-1) == -1) // unknown layout: no limit, as before
        // Real Macs have at least two levels; the slowest one is never counted as fast.
        let fast = mulg_engine_fast_core_count()
        #expect(fast == -1 || (fast > 0 && fast < ProcessInfo.processInfo.processorCount))
    }

    @Test("On by default, and a saved choice is kept")
    func setting() throws {
        #expect(GameSettings().mulg.engine.prioritizeGameThreads)
        var off = GameSettings()
        off.mulg.engine.prioritizeGameThreads = false
        #expect(try !SettingsStore.decode(PropertyListEncoder().encode(off)).mulg.engine.prioritizeGameThreads)
    }
}
