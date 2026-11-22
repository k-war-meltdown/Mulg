import Foundation
@testable import MulgGraphics
import Synchronization
import Testing
import QuartzCore

@Suite("Presented-frame batching")
struct FrameBatchTests {
    @Test func unorderedCompletionsDrainChronologicallyAndIgnoreInvalidTimes() {
        let wakes = Mutex(0)
        let interceptor = GraphicsInterceptor { if case .framesPresented = $0 { wakes.withLock { $0 += 1 } } }
        for time in [3.0, 1, 2] { interceptor.framePresented(atTime: time) }
        #expect(interceptor.takePresentedFrames() == [1, 2, 3])
        #expect(wakes.withLock { $0 } == 1)
        interceptor.framePresented(atTime: .nan)
        interceptor.framePresented(atTime: .infinity)
        #expect(interceptor.takePresentedFrames().isEmpty)
        #expect(wakes.withLock { $0 } == 1)
    }
    @Test func drawableShortagesAreBoundedAndBelongToTheirSurface() {
        let failures = Mutex<[UInt64]>([])
        let interceptor = GraphicsInterceptor {
            if case .drawableUnavailable(let generation) = $0 { failures.withLock { $0.append(generation) } }
        }
        let first = CAMetalLayer(), next = CAMetalLayer()
        interceptor.attach(first)
        for _ in 0..<2 { interceptor.outputDrawableUnavailable(first) }
        #expect(failures.withLock { $0.isEmpty })
        for _ in 0..<100 { interceptor.outputDrawableUnavailable(first) }
        let generation = failures.withLock { $0.first }
        #expect(failures.withLock { $0.count } == 1)
        #expect(generation.map { interceptor.drawableIsUnavailable(generation: $0) } == true)
        interceptor.attach(next)
        #expect(generation.map { interceptor.drawableIsUnavailable(generation: $0) } == false)
        for _ in 0..<100 { interceptor.outputDrawableUnavailable(first) }
        #expect(failures.withLock { $0.count } == 1)
        interceptor.outputDrawableUnavailable(next)
        #expect(failures.withLock { $0.count } == 1)
    }
    @Test("Old GPU failures cannot disable a replacement surface, and duplicate failures report once")
    func gpuFailureOwnership() {
        let errors = Mutex<[String]>([])
        let interceptor = GraphicsInterceptor { signal in
            if case .gpuExecutionFailed(let message, _) = signal { errors.withLock { $0.append(message) } }
        }
        let first = CAMetalLayer(), replacement = CAMetalLayer()
        interceptor.attach(first)
        interceptor.attach(replacement)
        interceptor.gpuFailed("old surface", generation: 1)
        #expect(errors.withLock { $0.isEmpty })
        interceptor.gpuFailed("current surface", generation: 2)
        interceptor.gpuFailed("duplicate completion", generation: 2)
        #expect(errors.withLock { $0 } == ["current surface"])
        interceptor.attach(first)
        interceptor.gpuFailed("recovered surface", generation: 3)
        #expect(errors.withLock { $0 } == ["current surface", "recovered surface"])
    }
    @Test func queuedFailuresKeepTheirGenerationUntilConsumption() {
        let signals = Mutex<[GraphicsSignal]>([])
        let interceptor = GraphicsInterceptor { signal in signals.withLock { $0.append(signal) } }
        let first = CAMetalLayer(), second = CAMetalLayer()
        interceptor.attach(first)
        interceptor.layerUsesUnsupportedPresentPath(first)
        interceptor.gpuFailed("queued", generation: 1)
        interceptor.attach(second)
        for signal in signals.withLock({ $0 }) {
            switch signal {
            case .gpuExecutionFailed(_, let generation), .unsupportedPresentPath(let generation):
                #expect(!interceptor.isCurrent(generation: generation))
            default: Issue.record("expected an attachment-scoped failure")
            }
        }
        interceptor.layerUsesUnsupportedPresentPath(first)
        #expect(signals.withLock { $0.count } == 2, "an old layer cannot report against the new attachment")
        interceptor.layerUsesUnsupportedPresentPath(second)
        if case .unsupportedPresentPath(let generation)? = signals.withLock({ $0.last }) {
            #expect(interceptor.isCurrent(generation: generation))
        } else { Issue.record("current failure expected") }
    }

    @Test func surfaceActivityIsCoalescedBoundedAndKeepsRenderTimestamps() {
        let wakes = Mutex(0)
        let interceptor = GraphicsInterceptor { if case .layerCandidatesChanged = $0 { wakes.withLock { $0 += 1 } } }
        let first = CAMetalLayer(), second = CAMetalLayer()
        let before = CACurrentMediaTime()
        for _ in 0..<100 { interceptor.mainLayerCandidateChanged(first); interceptor.mainLayerCandidateChanged(second) }
        let after = CACurrentMediaTime()
        let activity = interceptor.takeLayerCandidates()
        #expect(wakes.withLock { $0 } == 1)
        #expect(activity.count == 2)
        #expect(activity.allSatisfy { $0.time >= before && $0.time <= after })
        for _ in 0..<100 { interceptor.mainLayerCandidateChanged(CAMetalLayer()) }
        #expect(interceptor.takeLayerCandidates().count == 64)
        #expect(wakes.withLock { $0 } == 2)
    }
    @Test("Many frames wake the main thread once until it takes them")
    func batching() {
        let wakes = Mutex(0)
        let interceptor = GraphicsInterceptor { signal in
            if case .framesPresented = signal {
                wakes.withLock { $0 += 1 }
            }
        }
        for index in 0..<5 {
            interceptor.framePresented(atTime: Double(index))
        }
        #expect(wakes.withLock { $0 } == 1)
        #expect(interceptor.takePresentedFrames() == [0, 1, 2, 3, 4])
        #expect(interceptor.takePresentedFrames().isEmpty)
        interceptor.framePresented(atTime: 9)
        #expect(wakes.withLock { $0 } == 2, "after a take, the next frame wakes the main thread again")
    }

    @Test("A stalled main thread keeps only the newest frames")
    func cap() {
        let interceptor = GraphicsInterceptor { _ in }
        for index in 0..<2_000 {
            interceptor.framePresented(atTime: Double(index))
        }
        let frames = interceptor.takePresentedFrames()
        #expect(frames.count < 1_024)
        #expect(frames.last == 1_999)
    }
}
