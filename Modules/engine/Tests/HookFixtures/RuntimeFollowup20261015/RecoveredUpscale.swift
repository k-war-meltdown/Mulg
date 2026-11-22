import Foundation
import Synchronization
public typealias CFTimeInterval = Double
func CACurrentMediaTime() -> Double { ProcessInfo.processInfo.systemUptime }
public final class CAMetalLayer: @unchecked Sendable {}
public protocol MTLTexture: AnyObject {}
enum Status { case completed, error }
public protocol MTLCommandBuffer: AnyObject {
    func addCompletedHandler(_ handler: @escaping (Buffer) -> Void)
}
public final class Buffer: MTLCommandBuffer {
    var status = Status.completed, error: NSError?
    public func addCompletedHandler(_ handler: @escaping (Buffer) -> Void) {}
}
final class Texture: MTLTexture {}
public protocol MulgGraphicsDelegate {}
public final class MetalFXUpscaler {
    public enum Failure: Equatable, Sendable { case scalerUnavailable }
    nonisolated(unsafe) static var failing = true
    func removeAll() {}
    func encode(into: any MTLCommandBuffer, source: any MTLTexture, destination: any MTLTexture, extendedRange: Bool) -> Failure? {
        Self.failing ? .scalerUnavailable : nil
    }
    func encodeFallback(into: any MTLCommandBuffer, source: any MTLTexture, destination: any MTLTexture) -> Bool { true }
}
// __PRODUCTION__
let signals = Mutex<[GraphicsSignal]>([])
let interceptor = GraphicsInterceptor { signal in signals.withLock { $0.append(signal) } }
let layer = CAMetalLayer(), texture = Texture(), buffer = Buffer()
interceptor.attach(layer)
for _ in 0..<3 { assert(interceptor.upscale(texture, into: texture, commandBuffer: buffer, extendedRange: false)) }
let generation = signals.withLock { values -> UInt64 in
    for value in values { if case .upscaleFailing(_, let generation) = value { return generation } }; return 0
}
assert(generation != 0)
MetalFXUpscaler.failing = false
assert(interceptor.upscale(texture, into: texture, commandBuffer: buffer, extendedRange: false))
let shouldBlock = // __CHECK__
assert(!shouldBlock, "A queued failure must not disable an upscaler that has already recovered")
print("PASS: recovered upscale frames invalidate stale failure signals")
