import Foundation
import Metal
import MulgGraphicsHooks
import QuartzCore
import Synchronization

/// Passes a non-Sendable object (a layer) from a render thread to the main actor. Only used
/// where the receiver touches the object on the main thread, as Core Animation expects.
public struct MainThreadTransfer<Value>: @unchecked Sendable {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}

/// What the render-thread side tells the graphics module.
public enum GraphicsSignal: Sendable {
    case layerCandidatesChanged
    case gameUsesOwnMetalFX(String)
    case unsupportedPresentPath(generation: UInt64)
    case drawableUnavailable(generation: UInt64)
    case upscaleFailing(MetalFXUpscaler.Failure, generation: UInt64)
    case gpuExecutionFailed(String, generation: UInt64)
    /// Presented frames are waiting; `takePresentedFrames()` hands them over. One signal covers
    /// every frame presented until the main thread takes them.
    case framesPresented
}

/// The delegate the Objective-C presentation hooks call (PLAN.md §5.2.3–5.2.6).
///
/// `upscale(_:into:commandBuffer:)` runs on the game's render thread for every frame of the
/// upscaling layer: it encodes the MetalFX upscale of the game's small frame into a drawable of
/// the game's own layer (design B).
public final class GraphicsInterceptor: NSObject, MulgGraphicsDelegate, @unchecked Sendable {
    private struct State {
        var attached = false
        var consecutiveFailures = 0
        var consecutiveDrawableFailures = 0
        var reportedUnsupportedPath = false
        var generation: UInt64 = 0
        var reportedGPUFailure = false
        var upscaleFailurePending = false
        var layer: ObjectIdentifier?
    }

    private let state = Mutex(State())
    // Presented times waiting for the main thread, kept apart from `state` so the upscale path
    // never waits on them.
    private struct PresentedFrames {
        var times: [Double] = []
        var drainPending = false
    }

    private let presented = Mutex(PresentedFrames())
    public typealias LayerActivity = (layer: MainThreadTransfer<CAMetalLayer>, time: CFTimeInterval)
    private struct Candidates {
        var layers: [ObjectIdentifier: LayerActivity] = [:]
        var drainPending = false
    }
    private let candidates = Mutex(Candidates())
    // Detection is launch-wide. Games may recreate/alternate scaler types every frame;
    // those allocations must not enqueue the same warning repeatedly on the main thread.
    private let reportedGameMetalFX = Mutex(Set<String>())
    private let upscaler = MetalFXUpscaler()
    private let signal: @Sendable (GraphicsSignal) -> Void

    /// Failures in a row before the layer is reported as failing and switched off. Every failure
    /// is a frame the player never sees, and none of them goes away on its own for the same
    /// sizes and formats, so only a passing one (an allocation that failed once) is waited out.
    static let failureLimit = 3

    public init(signal: @escaping @Sendable (GraphicsSignal) -> Void) {
        self.signal = signal
    }

    public func attach(_ layer: CAMetalLayer?) {
        let attached = layer != nil
        state.withLock { state in
            state.attached = attached
            state.layer = layer.map(ObjectIdentifier.init)
            state.consecutiveFailures = 0
            state.consecutiveDrawableFailures = 0
            state.reportedUnsupportedPath = false
            state.generation &+= 1
            state.reportedGPUFailure = false
            state.upscaleFailurePending = false
        }
        // Scalers hold their last frame's textures; a detached layer's are not kept, and a new
        // one starts clean.
        upscaler.removeAll()
    }

    public func purgeCaches() {
        upscaler.removeAll() // Encoded command buffers retain their own resources until completion.
        presented.withLock { $0.times.removeAll() }
    }

    /// Check again when the main queue consumes a failure, after any surface replacement.
    func isCurrent(generation: UInt64) -> Bool {
        state.withLock { $0.generation == generation }
    }

    func drawableIsUnavailable(generation: UInt64) -> Bool {
        state.withLock { $0.attached && $0.generation == generation && $0.consecutiveDrawableFailures == Self.failureLimit }
    }

    func upscaleIsFailing(generation: UInt64) -> Bool {
        state.withLock { $0.attached && $0.generation == generation && $0.upscaleFailurePending }
    }

    // MARK: MulgGraphicsDelegate

    public func upscale(_ source: any MTLTexture, into destination: any MTLTexture,
                        commandBuffer: any MTLCommandBuffer, extendedRange: Bool) -> Bool {
        guard let generation = state.withLock({ state -> UInt64? in
            guard state.attached else { return nil }
            state.consecutiveDrawableFailures = 0
            return state.generation
        }) else {
            return false
        }
        let failure = upscaler.encode(
            into: commandBuffer,
            source: source,
            destination: destination,
            extendedRange: extendedRange)
        let visible = failure == nil || upscaler.encodeFallback(into: commandBuffer, source: source, destination: destination)
        let failures = state.withLock { state -> Int in
            guard state.generation == generation else { return 0 }
            state.consecutiveFailures = failure == nil ? 0 : state.consecutiveFailures + 1
            state.upscaleFailurePending = failure != nil && (state.consecutiveFailures >= Self.failureLimit || !visible)
            return state.consecutiveFailures
        }
        if visible {
            commandBuffer.addCompletedHandler { [weak self] completed in
                guard completed.status == .error, let self else { return }
                self.gpuFailed(completed.error?.localizedDescription ?? "GPU command failed", generation: generation)
            }
        }
        if let failure, (failures == Self.failureLimit || !visible), isCurrent(generation: generation) {
            signal(.upscaleFailing(failure, generation: generation))
        }
        return visible
    }

    func gpuFailed(_ message: String, generation: UInt64) {
        let report = state.withLock { state -> Bool in
            guard state.attached, state.generation == generation, !state.reportedGPUFailure else { return false }
            state.reportedGPUFailure = true
            state.attached = false
            return true
        }
        if report {
            upscaler.removeAll()
            signal(.gpuExecutionFailed(message, generation: generation))
        }
    }

    public func mainLayerCandidateChanged(_ layer: CAMetalLayer) {
        let time = CACurrentMediaTime()
        let wake = candidates.withLock { batch -> Bool in
            let identity = ObjectIdentifier(layer)
            if batch.layers.count >= 64, batch.layers[identity] == nil,
               let oldest = batch.layers.min(by: { $0.value.time < $1.value.time })?.key {
                batch.layers.removeValue(forKey: oldest)
            }
            batch.layers[identity] = (MainThreadTransfer(layer), time)
            guard !batch.drainPending else { return false }
            batch.drainPending = true
            return true
        }
        if wake { signal(.layerCandidatesChanged) }
    }

    public func takeLayerCandidates() -> [LayerActivity] {
        candidates.withLock { batch in
            batch.drainPending = false
            let activity = Array(batch.layers.values)
            batch.layers.removeAll(keepingCapacity: true)
            return activity
        }
    }

    public func gameCreatedMetalFXObject(_ feature: String) {
        guard reportedGameMetalFX.withLock({ $0.insert(feature).inserted }) else { return }
        signal(.gameUsesOwnMetalFX(feature))
    }

    public func layerUsesUnsupportedPresentPath(_ layer: CAMetalLayer) {
        let generation = state.withLock { state -> UInt64? in
            guard state.attached, state.layer == ObjectIdentifier(layer), !state.reportedUnsupportedPath else { return nil }
            state.reportedUnsupportedPath = true
            return state.generation
        }
        if let generation {
            signal(.unsupportedPresentPath(generation: generation))
        }
    }

    public func outputDrawableUnavailable(_ layer: CAMetalLayer) {
        let generation = state.withLock { state -> UInt64? in
            guard state.attached, state.layer == ObjectIdentifier(layer),
                  state.consecutiveDrawableFailures < Self.failureLimit else { return nil }
            state.consecutiveDrawableFailures += 1
            return state.consecutiveDrawableFailures == Self.failureLimit ? state.generation : nil
        }
        if let generation { signal(.drawableUnavailable(generation: generation)) }
    }

    /// Called on a Metal completion thread for every presented frame (up to 120 a second).
    /// Upstream-style one-hop-per-frame cost a Task and a main-thread turn each; here frames are
    /// batched and the main thread is woken only when it has taken the previous batch.
    public func framePresented(atTime time: CFTimeInterval) {
        guard time.isFinite else { return }
        let wake = presented.withLock { batch -> Bool in
            if batch.times.count >= 1024 {
                // The main thread is stalled; keep the newest frames only.
                batch.times.removeFirst(512)
            }
            batch.times.append(time)
            guard !batch.drainPending else { return false }
            batch.drainPending = true
            return true
        }
        if wake {
            signal(.framesPresented)
        }
    }

    /// The frames presented since the last call, oldest first.
    public func takePresentedFrames() -> [Double] {
        presented.withLock { batch -> [Double] in
            batch.drainPending = false
            let times = batch.times.sorted()
            batch.times.removeAll(keepingCapacity: true)
            return times
        }
    }
}
