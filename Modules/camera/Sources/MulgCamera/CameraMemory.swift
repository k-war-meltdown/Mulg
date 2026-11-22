import Foundation
import MulgCameraHooks
import MulgContracts

/// Swift face of the value search in MulgCameraMemory.m. Blocking: call from `CameraMemory.queue`,
/// never from the main thread, except the single-word reads and swaps.
nonisolated enum CameraMemory {
    /// Every scan and search runs here, one at a time.
    /// Background priority: on Apple silicon that runs only on the efficiency cores and always
    /// yields to the game's threads, so a scan never takes CPU time from the game.
    static let queue = DispatchQueue(label: "io.mulg.camera.memory", qos: .background)
    /// The few reads that keep a raised limit in place; separate so a scan never delays them.
    static let keeperQueue = DispatchQueue(label: "io.mulg.camera.keeper", qos: .background)

    /// Plausible camera distances, in game units. Wide on purpose: games use metres, centimetres
    /// or their own scale; the zoom steps narrow the candidates, not this range.
    static let searchRange: ClosedRange<Float> = 0.3...200
    /// Narrower ranges tried in turn when the wide one holds more than `candidateLimit` values
    /// (large games late in a session, or at high render resolutions). Common camera distances
    /// sit well inside each.
    static let fallbackRanges: [ClosedRange<Float>] = [0.5...80, 1...40, 1.5...25]
    /// At most this many first-step candidates (8 bytes each, so at most 192 MB of scratch memory,
    /// given back as soon as the four steps are done).
    static let candidateLimit: UInt64 = 24_000_000
    /// Zooming in must bring a value down by at least this factor to count.
    static let minimumZoomRatio: Float = 1.05
    /// How far apart (bytes) a camera's farthest and nearest limits may sit in its settings.
    static let pairWindow: Int32 = 256
    /// More pairs than this for one limit means the values are too common to be a camera's.
    static let pairLimit = 64

    /// A value that followed the zoom, with its value zoomed out (`farthest`) and zoomed in (`nearest`).
    /// Values are held masked, so a later pair search never finds them in Mulg's own memory.
    struct Survivor: Sendable, Equatable {
        let address: UInt64
        private let farthestMasked: UInt32
        private let nearestMasked: UInt32

        init(address: UInt64, farthestBits: UInt32, nearestBits: UInt32) {
            self.address = address
            farthestMasked = farthestBits ^ CameraCalibration.mask
            nearestMasked = nearestBits ^ CameraCalibration.mask
        }

        var farthestBits: UInt32 { farthestMasked ^ CameraCalibration.mask }
        var nearestBits: UInt32 { nearestMasked ^ CameraCalibration.mask }
    }

    static func read(_ address: UInt64) -> UInt32? {
        var bits: UInt32 = 0
        return mulg_camera_read(address, &bits) ? bits : nil
    }

    static func readFloat(_ address: UInt64) -> Float? {
        read(address).map(Float.init(bitPattern:))
    }

    /// One pending compare-and-swap.
    struct Swap: Sendable {
        let address: UInt64
        let expected: UInt32
        let replacement: UInt32
    }

    enum SwapResult { case swapped, different, unavailable }

    static func swap(_ address: UInt64, expected: UInt32, replacement: UInt32) -> SwapResult {
        switch mulg_camera_swap(address, expected, replacement) {
        case 1: .swapped
        case 0: .different
        default: .unavailable
        }
    }

    /// Farthest limits (addresses) with the byte offset to their nearest limit.
    struct Pair: Sendable, Equatable {
        let address: UInt64
        let offset: Int32
    }

    /// Every farthest limit with its nearest limit beside it. `offsets` restricts where the nearest
    /// may sit (a saved calibration); without it, anywhere within `pairWindow`. Returns nil when
    /// there are more than `pairLimit`.
    static func pairs(farthestBits: UInt32, nearestBits: UInt32, offsets: [Int32] = [],
                      excluding excluded: [UInt64] = []) -> [Pair]? {
        var found = [MulgCameraPair](repeating: MulgCameraPair(address: 0, offset: 0), count: pairLimit)
        let total = offsets.withUnsafeBufferPointer { offsetBuffer in
            excluded.withUnsafeBufferPointer { excludedBuffer in
                found.withUnsafeMutableBufferPointer { output in
                    mulg_camera_find_pairs(farthestBits, nearestBits, offsetBuffer.baseAddress, offsetBuffer.count,
                                           pairWindow, excludedBuffer.baseAddress, excludedBuffer.count,
                                           output.baseAddress, UInt64(output.count))
                }
            }
        }
        guard total <= UInt64(pairLimit) else { return nil }
        return found.prefix(Int(total)).map { Pair(address: $0.address, offset: $0.offset) }
    }
}

/// One value search in progress (MulgCameraScan). Used only on `CameraMemory.queue`.
nonisolated final class CameraScan: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case tooMany, noMemory
    }

    private let scan: OpaquePointer

    /// Step one: every plausible value as it is now (zoomed all the way out).
    init(range: ClosedRange<Float> = CameraMemory.searchRange, limit: UInt64 = CameraMemory.candidateLimit) throws(Failure) {
        var status = MulgCameraScanStatus.OK
        guard let scan = mulg_camera_scan_create(range.lowerBound, range.upperBound, limit, &status) else {
            throw status == .tooMany ? .tooMany : .noMemory
        }
        self.scan = scan
    }

    /// Step one over the widest range that fits: `searchRange`, then each of `fallbackRanges`.
    /// Throws `.tooMany` only when even the narrowest overflows.
    static func widest() throws(Failure) -> (scan: CameraScan, range: ClosedRange<Float>) {
        var lastFailure = Failure.tooMany
        for range in [CameraMemory.searchRange] + CameraMemory.fallbackRanges {
            do throws(Failure) {
                return (try CameraScan(range: range), range)
            } catch {
                lastFailure = error
                guard error == .tooMany else { break }
            }
        }
        throw lastFailure
    }

    deinit { mulg_camera_scan_free(scan) }

    var count: UInt64 { mulg_camera_scan_count(scan) }

    /// Keeps values that went down since step one (zoomed in); returns how many remain.
    func keepDecreased() -> UInt64 { mulg_camera_scan_filter(scan, .decreased, CameraMemory.minimumZoomRatio) }
    /// Keeps values back at exactly their zoomed-out value.
    func keepFarthestAgain() -> UInt64 { mulg_camera_scan_filter(scan, .equalsFirst, 1) }
    /// Keeps values back at exactly their zoomed-in value.
    func keepNearestAgain() -> UInt64 { mulg_camera_scan_filter(scan, .equalsSecond, 1) }

    func survivors(limit: Int = 4096) -> [CameraMemory.Survivor] {
        let capacity = min(Int(count), limit)
        guard capacity > 0 else { return [] }
        var addresses = [UInt64](repeating: 0, count: capacity)
        var first = [UInt32](repeating: 0, count: capacity)
        var second = [UInt32](repeating: 0, count: capacity)
        let copied = Int(mulg_camera_scan_results(scan, &addresses, &first, &second, UInt64(capacity)))
        let survivors = (0..<copied).map {
            CameraMemory.Survivor(address: addresses[$0], farthestBits: first[$0], nearestBits: second[$0])
        }
        // Scrub the plain copies before the arrays go back to the allocator.
        for index in first.indices { first[index] = 0; second[index] = 0 }
        return survivors
    }
}

extension CameraMemory {
    /// Limit pairs for several groups in one pass over memory. Per group: its pairs, or nil when it
    /// has more than `pairLimit` (too common to be a camera's) or a nearest value of 0.
    static func pairs(for groups: [CameraCalibrationPlan.Group], excluding excluded: [UInt64]) -> [[Pair]?] {
        guard !groups.isEmpty else { return [] }
        let far = groups.map(\.farthestBits), near = groups.map(\.nearestBits)
        let capacity = pairLimit * groups.count
        var found = [MulgCameraSetPair](repeating: MulgCameraSetPair(address: 0, offset: 0, set: 0), count: capacity)
        var totals = [UInt64](repeating: 0, count: groups.count)
        let copied = far.withUnsafeBufferPointer { farBuffer in
            near.withUnsafeBufferPointer { nearBuffer in
                excluded.withUnsafeBufferPointer { excludedBuffer in
                    found.withUnsafeMutableBufferPointer { output in
                        totals.withUnsafeMutableBufferPointer { totalBuffer in
                            mulg_camera_find_pair_sets(farBuffer.baseAddress!, nearBuffer.baseAddress!, groups.count, pairWindow,
                                                       excludedBuffer.baseAddress, excludedBuffer.count,
                                                       output.baseAddress, UInt64(output.count), totalBuffer.baseAddress!)
                        }
                    }
                }
            }
        }
        let list = found.prefix(Int(min(copied, UInt64(capacity))))
        return groups.indices.map { index in
            guard groups[index].nearestBits != 0, totals[index] <= UInt64(pairLimit) else { return nil }
            return list.filter { Int($0.set) == index }.map { Pair(address: $0.address, offset: $0.offset) }
        }
    }

    /// Where a value lives, for the calibration report: VM tag, and the region's start and size.
    static func region(of address: UInt64) -> (tag: UInt32, start: UInt64, size: UInt64)? {
        var tag: UInt32 = 0, start: UInt64 = 0, size: UInt64 = 0
        return mulg_camera_region(address, &tag, &start, &size) ? (tag, start, size) : nil
    }
}
