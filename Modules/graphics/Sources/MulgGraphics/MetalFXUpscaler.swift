import Foundation
import Metal
import MetalFX
import MetalPerformanceShaders
import MulgGraphicsHooks

/// Encodes MetalFX spatial upscaling (PLAN.md §5.2.6). Used on the game's render thread.
///
/// One scaler per size and format combination, created once and reused. A new window size,
/// preset (render size), pixel format or colour mode gives a new combination.
public final class MetalFXUpscaler: @unchecked Sendable {
    struct Key: Hashable {
        let device: ObjectIdentifier
        let inputWidth: Int
        let inputHeight: Int
        let outputWidth: Int
        let outputHeight: Int
        let inputFormat: UInt
        let outputFormat: UInt
        let mode: Int
    }

    public enum Failure: Equatable, Sendable {
        case deviceUnsupported
        case scalerUnavailable
        case textureUsageMismatch
        case deviceMismatch
    }

    // Scalers are not Sendable, so a plain lock guards the cache instead of a Mutex.
    private let lock = NSLock()
    private var cache: [Key: any MTLFXSpatialScaler] = [:]
    private var fallback: MPSImageBilinearScale?
    /// Only a few combinations are ever live; drop old ones rather than grow.
    private let maximumCachedScalers = 4

    /// Only ownership crosses the completion callback; these objects are never accessed there.
    private struct InFlightResources: @unchecked Sendable { let objects: [AnyObject] }
    private func retainUntilComplete(_ objects: [AnyObject], buffer: any MTLCommandBuffer) {
        guard !buffer.retainedReferences else { return }
        let resources = InFlightResources(objects: objects)
        buffer.addCompletedHandler { _ in withExtendedLifetime(resources) {} }
    }

    public init() {}

    /// Drops every scaler, and with them the textures of the last frame each one encoded.
    public func removeAll() {
        lock.withLock { cache.removeAll(); fallback = nil }
    }

    public static func isSupported(on device: any MTLDevice) -> Bool {
        MTLFXSpatialScalerDescriptor.supportsDevice(device)
    }

    /// Perceptual for gamma-encoded 8/10-bit content, `_srgb` formats included (Apple's MetalFX
    /// sample pairs `bgra8Unorm_srgb` with `.perceptual`), linear for float formats, HDR for
    /// extended-range content.
    public static func colorProcessingMode(for format: MTLPixelFormat, extendedRange: Bool)
        -> MTLFXSpatialScalerColorProcessingMode {
        if extendedRange {
            return .hdr
        }
        switch format {
        case .rgba16Float, .rgba32Float, .rg11b10Float, .rgb9e5Float:
            return .linear
        default:
            return .perceptual
        }
    }

    /// Encodes an upscale of `source` into `destination`. Returns nil on success.
    public func encode(
        into commandBuffer: any MTLCommandBuffer,
        source: any MTLTexture,
        destination: any MTLTexture,
        extendedRange: Bool
    ) -> Failure? {
        guard source.device === commandBuffer.device, destination.device === commandBuffer.device else {
            return .deviceMismatch
        }
        let mode = Self.colorProcessingMode(for: source.pixelFormat, extendedRange: extendedRange)
        let key = Key(
            device: ObjectIdentifier(commandBuffer.device),
            inputWidth: source.width, inputHeight: source.height,
            outputWidth: destination.width, outputHeight: destination.height,
            inputFormat: source.pixelFormat.rawValue, outputFormat: destination.pixelFormat.rawValue,
            mode: mode.rawValue)

        return lock.withLock { () -> Failure? in
            let scaler: any MTLFXSpatialScaler
            if let existing = cache[key] {
                scaler = existing
            } else {
                // Checked only when a scaler is made, not on every frame.
                let device = commandBuffer.device
                guard Self.isSupported(on: device) else {
                    return .deviceUnsupported
                }
                guard let created = Self.makeScaler(key: key, mode: mode, device: device) else {
                    return .scalerUnavailable
                }
                if cache.count >= maximumCachedScalers {
                    cache.removeAll()
                }
                cache[key] = created
                scaler = created
            }
            guard source.usage.contains(scaler.colorTextureUsage),
                  destination.usage.contains(scaler.outputTextureUsage) else {
                return .textureUsageMismatch
            }
            scaler.colorTexture = source
            scaler.outputTexture = destination
            scaler.inputContentWidth = source.width
            scaler.inputContentHeight = source.height
            scaler.encode(commandBuffer: commandBuffer)
            retainUntilComplete([scaler as AnyObject, source as AnyObject, destination as AnyObject], buffer: commandBuffer)
            return nil
        }
    }

    private static func makeScaler(key: Key, mode: MTLFXSpatialScalerColorProcessingMode,
                                   device: any MTLDevice) -> (any MTLFXSpatialScaler)? {
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = key.inputWidth
        descriptor.inputHeight = key.inputHeight
        descriptor.outputWidth = key.outputWidth
        descriptor.outputHeight = key.outputHeight
        descriptor.colorTextureFormat = MTLPixelFormat(rawValue: key.inputFormat) ?? .bgra8Unorm
        descriptor.outputTextureFormat = MTLPixelFormat(rawValue: key.outputFormat) ?? .bgra8Unorm
        descriptor.colorProcessingMode = mode
        // Our own scaler must not be mistaken for the game's (§5.2.7).
        mulg_graphics_begin_own_metalfx()
        defer { mulg_graphics_end_own_metalfx() }
        return descriptor.makeSpatialScaler(device: device)
    }

    /// Keep a failed MetalFX frame visible using the platform's simple scaler.
    func encodeFallback(into buffer: any MTLCommandBuffer, source: any MTLTexture, destination: any MTLTexture) -> Bool {
        let formats: Set<MTLPixelFormat> = [.bgra8Unorm, .bgra8Unorm_srgb, .rgba8Unorm, .rgba8Unorm_srgb,
                                          .rgba16Float, .rgba32Float]
        guard source.device === buffer.device, destination.device === buffer.device,
              source.usage.contains(.shaderRead), destination.usage.contains(.shaderWrite),
              formats.contains(source.pixelFormat), formats.contains(destination.pixelFormat),
              source.textureType == .type2D, destination.textureType == .type2D,
              MPSSupportsMTLDevice(buffer.device) else { return false }
        return lock.withLock {
            if fallback?.device !== buffer.device {
                fallback = MPSImageBilinearScale(device: buffer.device)
                fallback?.edgeMode = .clamp
            }
            fallback?.encode(commandBuffer: buffer, sourceTexture: source, destinationTexture: destination)
            if let fallback {
                retainUntilComplete([fallback, source as AnyObject, destination as AnyObject], buffer: buffer)
            }
            return true
        }
    }
}
