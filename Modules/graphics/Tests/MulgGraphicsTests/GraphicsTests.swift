import CoreGraphics
import Metal
import MetalFX
import MetalPerformanceShaders
import Testing
import MulgContracts
import MulgGraphicsHooks
@testable import MulgGraphics

@Suite("Visible upscale fallback")
struct UpscaleFallbackTests {
    @Test(.enabled(if: MTLCreateSystemDefaultDevice().map { MPSSupportsMTLDevice($0) } ?? false))
    func presentsTheSourcePixelsAtTheOutputSize() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 2, height: 2, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        let source = try #require(device.makeTexture(descriptor: descriptor))
        descriptor.width = 4; descriptor.height = 4
        let destination = try #require(device.makeTexture(descriptor: descriptor))
        // Typed: Swift 6.4 infers an untyped flatMap of this literal as [Any], uploading boxes, not bytes.
        let pixel: [UInt8] = [64, 128, 192, 255]
        let pixels: [UInt8] = Array(Array(repeating: pixel, count: 4).joined())
        pixels.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 8) }
        let buffer = try #require(queue.makeCommandBuffer())
        #expect(MetalFXUpscaler().encodeFallback(into: buffer, source: source, destination: destination))
        buffer.commit(); buffer.waitUntilCompleted()
        #expect(buffer.status == .completed)
        var output = [UInt8](repeating: 0, count: 64)
        output.withUnsafeMutableBytes { destination.getBytes($0.baseAddress!, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0) }
        #expect(output == Array(Array(repeating: pixel, count: 16).joined()))
    }
}

@Suite("MetalFX colour processing")
struct ColorProcessingTests {
    @Test("8- and 10-bit gamma formats use perceptual processing")
    func perceptual() {
        #expect(MetalFXUpscaler.colorProcessingMode(for: .bgra8Unorm, extendedRange: false) == .perceptual)
        #expect(MetalFXUpscaler.colorProcessingMode(for: .bgra8Unorm_srgb, extendedRange: false) == .perceptual)
        #expect(MetalFXUpscaler.colorProcessingMode(for: .bgr10a2Unorm, extendedRange: false) == .perceptual)
    }

    @Test("Float formats use linear processing, extended range uses HDR")
    func linearAndHDR() {
        #expect(MetalFXUpscaler.colorProcessingMode(for: .rgba16Float, extendedRange: false) == .linear)
        #expect(MetalFXUpscaler.colorProcessingMode(for: .rgba16Float, extendedRange: true) == .hdr)
    }
}

@Suite("Reduced drawable size")
struct ReducedSizeTests {
    @Test("The hooks reduce sizes exactly like the Swift presets", arguments: MetalFXPreset.allCases)
    func matchesPresets(preset: MetalFXPreset) {
        for (width, height) in [(2560, 1600), (3024, 1964), (1920, 1080), (1001, 777)] {
            let reduced = mulg_graphics_reduced_size(CGSize(width: width, height: height), Int32(preset.renderPercent))
            let expected = preset.renderSize(forOutputWidth: width, height: height)
            #expect(Int(reduced.width) == expected.width, "\(preset) \(width)")
            #expect(Int(reduced.height) == expected.height, "\(preset) \(height)")
        }
    }

    @Test("100 percent leaves the size unchanged")
    func fullSize() {
        let size = CGSize(width: 1234, height: 777)
        #expect(mulg_graphics_reduced_size(size, 100) == size)
    }
}

@Suite("MetalFX blockers")
struct BlockerTests {
    @Test("Every reason the layer is switched off has a message for the user")
    func messages() {
        let reasons: [MetalFXBlocker] = [
            .gameUsesOwnMetalFX("temporal"), .unsupportedPresentPath, .notSupported("this GPU")
        ]
        for reason in reasons {
            #expect(!reason.message.isEmpty)
        }
        #expect(MetalFXBlocker.gameUsesOwnMetalFX("temporal").message.contains("temporal"))
    }
}

@Suite("Battery saver preset")
struct BatterySaverPresetTests {
    @Test("Battery saver caps the preset at Performance and leaves lighter ones alone")
    func lightened() {
        #expect(MetalFXPreset.quality.forBatterySaver(true) == .performance)
        #expect(MetalFXPreset.balanced.forBatterySaver(true) == .performance)
        #expect(MetalFXPreset.ultraPerformance.forBatterySaver(true) == .ultraPerformance)
        #expect(MetalFXPreset.allCases.allSatisfy { $0.forBatterySaver(false) == $0 })
    }
}

@Suite("Frame limiter (§6.1, §13.1)")
struct FrameLimiterTests {
    @Test("Low-refresh displays retain their actual scanout period", arguments: [24, 30, 48, 50, 60, 120, 144])
    func actualRefresh(rate: Int) {
        #expect(FrameLimiter.refreshRate(rate) == Double(rate))
        #expect(FrameLimiter.refreshesPerFrame(framesPerSecond: rate - 2, refreshRate: rate) == Double(rate) / Double(rate - 2))
        #expect(FrameLimiter.refreshesPerFrame(framesPerSecond: rate, refreshRate: rate) == 0)
    }
    @Test func invalidRefreshUsesFallback() {
        #expect(FrameLimiter.refreshRate(0) == 60)
        #expect(FrameLimiter.refreshRate(-1) == 60)
    }
    @Test("No limit at or above the refresh rate, or at 0")
    func noLimit() {
        #expect(FrameLimiter.refreshesPerFrame(framesPerSecond: 0, refreshRate: 120) == 0)
        #expect(FrameLimiter.refreshesPerFrame(framesPerSecond: 120, refreshRate: 120) == 0)
        #expect(FrameLimiter.refreshesPerFrame(framesPerSecond: 144, refreshRate: 120) == 0)
        #expect(FrameLimiter.refreshesPerFrame(framesPerSecond: 60, refreshRate: 120) == 2)
    }

    @Test func vsyncOffKeepsCapsAtAndAboveRefresh() {
        #expect(FrameLimiter.refreshesPerFrame(framesPerSecond: 60, refreshRate: 60, vsyncEnabled: false) == 1)
        #expect(FrameLimiter.refreshesPerFrame(framesPerSecond: 120, refreshRate: 60, vsyncEnabled: false) == 0.5)
        #expect(FrameLimiter.refreshesPerFrame(framesPerSecond: 0, refreshRate: 60, vsyncEnabled: false) == 0)
    }

    @Test("A limit that does not divide the refresh rate alternates holds and averages out")
    func unevenLimits() {
        for (fps, refresh, pattern) in [(90, 120, [1, 1, 2]), (45, 120, [2, 3, 3]), (60, 120, [2, 2, 2])] {
            var carry = 0.0
            let ratio = FrameLimiter.refreshesPerFrame(framesPerSecond: fps, refreshRate: refresh)
            let holds = (0..<30).map { _ in Int(mulg_graphics_next_hold(&carry, ratio)) }
            #expect(Array(holds.prefix(3)) == pattern)
            #expect(holds.reduce(0, +) == 30 * refresh / fps)
        }
    }
}

@Suite("Shader archive disk use")
@MainActor
struct ShaderArchivePruneTests {
    @Test("Other builds' archives go; this build's stay until they pass the limit")
    func prunes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = "Apple-M5-Version-27-0"
        let kept = [name + ".metallib", name + ".mtl4archive.0"]
        for file in kept + ["Apple-M5-Version-26-4.metallib", name + "-B.metallib"] {
            try Data(count: 10).write(to: folder.appendingPathComponent(file))
        }
        let files = { try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() }
        GraphicsModule.pruneShaderArchives(in: folder, keeping: name, limit: 20)
        #expect(try files() == kept.sorted())
        GraphicsModule.pruneShaderArchives(in: folder, keeping: name, limit: 19)
        #expect(try files().isEmpty)
    }
}

@Suite("Frame-rate unlock: present pacing", .serialized)
struct PresentPacingUnlockTests {
    @Test("1/60 and 1/30 s present minimums shorten to the unlock target; long holds and off are untouched")
    func shortensPacing() {
        defer { mulg_graphics_set_unlocked_frame_duration(0) }
        mulg_graphics_set_unlocked_frame_duration(1.0 / 120)
        #expect(abs(mulg_graphics_unlocked_duration(1.0 / 60) - 1.0 / 120) < 1e-9)
        #expect(abs(mulg_graphics_unlocked_duration(1.0 / 30) - 1.0 / 120) < 1e-9)
        #expect(mulg_graphics_unlocked_duration(1.0 / 120) == 1.0 / 120) // already fast enough
        #expect(mulg_graphics_unlocked_duration(0.5) == 0.5)               // a deliberate hold
        #expect(mulg_graphics_unlocked_duration(0) == 0)
        mulg_graphics_set_unlocked_frame_duration(0)
        #expect(mulg_graphics_unlocked_duration(1.0 / 60) == 1.0 / 60)
        mulg_graphics_set_unlocked_frame_duration(1.0 / 20) // not an unlock: ignored
        #expect(mulg_graphics_unlocked_duration(1.0 / 60) == 1.0 / 60)
    }
}
