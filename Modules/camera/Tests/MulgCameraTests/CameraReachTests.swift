import Foundation
import Testing
import MulgCameraHooks
import MulgContracts
@testable import MulgCamera

@Suite("Camera reach rules")
struct CameraReachPlanTests {
    @Test func stepsRunOutInOutIn() {
        let steps = CameraCalibrationPlan.Step.allCases
        #expect(steps.map(\.rawValue) == [1, 2, 3, 4])
        #expect(steps.map { $0.instruction.contains("OUT") } == [true, false, true, false])
        #expect(CameraCalibrationPlan.Step.nearestAgain.next == nil)
    }

    @Test func groupsKeepPlausibleLimitsUniqueFirst() {
        func survivor(_ address: UInt64, _ far: Float, _ near: Float) -> CameraMemory.Survivor {
            CameraMemory.Survivor(address: address, farthestBits: far.bitPattern, nearestBits: near.bitPattern)
        }
        let groups = CameraCalibrationPlan.groups([
            survivor(0x10, 8, 2), survivor(0x20, 8, 2), survivor(0x30, 5, 1.5),
            survivor(0x40, 2, 1.99), // barely moved: not a zoom
            survivor(0x50, .infinity, 1)
        ])
        // A value held once is the setting; copies are usually derived data the game rewrites.
        #expect(groups.count == 2)
        #expect(groups[0].farthest == 5)
        #expect(groups[1].farthest == 8 && groups[1].nearest == 2 && groups[1].addresses == [0x10, 0x20])
        // A normalised zoom level ends at exactly 0.
        #expect(CameraCalibrationPlan.groups([survivor(0x60, 1, 0)]).count == 1)
        #expect(CameraCalibrationPlan.groups([survivor(0x70, 30, 0)]).isEmpty)
    }

    @Test func raisedLimitFollowsReachAndClamps() {
        let far = Float(4).bitPattern
        #expect(Float(bitPattern: CameraCalibrationPlan.raisedBits(farthestBits: far, reach: 1.5)) == 6)
        #expect(Float(bitPattern: CameraCalibrationPlan.raisedBits(farthestBits: far, reach: 10)) == 12)
        #expect(CameraCalibrationPlan.passedLimit(4.2, farthest: 4))
        #expect(!CameraCalibrationPlan.passedLimit(4.01, farthest: 4))
        #expect(!CameraCalibrationPlan.passedLimit(1000, farthest: 4))
        #expect(!CameraCalibrationPlan.passedLimit(.infinity, farthest: 4))
    }

    @Test func integerBitsCannotCalibrateAsZoomDistances() {
        // These values appeared as the nearest zoom in Genshin's saved report.
        for bits: UInt32 in [7, 48, 113, 3_604_480] {
            let nearest = Float(bitPattern: bits)
            #expect(!CameraCalibrationPlan.isPlausible(farthest: 1, nearest: nearest))
            let saved = CameraCalibration(farthestBits: Float(1).bitPattern, nearestBits: bits,
                offsets: [4], pairs: 1, gameVersion: "7.2.0")
            #expect(!saved.isPlausible)
        }
        #expect(CameraCalibrationPlan.isPlausible(farthest: 1, nearest: 0))
        #expect(CameraCalibrationPlan.isPlausible(farthest: 1, nearest: 0.0001))
    }

    @Test func laterSearchesAreTrustedOnlyNearTheCalibratedCount() {
        #expect(!CameraCalibrationPlan.acceptsSearch(found: 0, calibrated: 2))
        #expect(CameraCalibrationPlan.acceptsSearch(found: 8, calibrated: 1))
        #expect(!CameraCalibrationPlan.acceptsSearch(found: 9, calibrated: 1))
    }

    @Test func calibrationRoundTripsAndStaysMaskedInMemory() throws {
        let value = CameraCalibration(farthestBits: Float(8).bitPattern, nearestBits: Float(2).bitPattern,
                                      offsets: [-4, 8], pairs: 2, gameVersion: "5.1 (1)")
        #expect(value.isPlausible)
        let decoded = try JSONDecoder().decode(CameraCalibration.self, from: JSONEncoder().encode(value))
        #expect(decoded == value && decoded.farthest == 8 && decoded.nearest == 2)
        // The raw limits must never sit side by side in Mulg's own memory.
        let words = withUnsafeBytes(of: value) { Array($0.bindMemory(to: UInt32.self)) }
        #expect(!words.contains(Float(8).bitPattern))
        #expect(!CameraCalibration(farthestBits: Float(2).bitPattern, nearestBits: Float(2).bitPattern,
                                   offsets: [4], pairs: 1, gameVersion: "").isPlausible)
    }

    @Test func settingsClampReach() throws {
        let data = Data(#"{"extendedReach":true,"reach":9}"#.utf8)
        let settings = try JSONDecoder().decode(CameraSettings.self, from: data)
        #expect(settings.extendedReach && settings.reach == 3)
        #expect(try JSONDecoder().decode(CameraSettings.self, from: Data("{}".utf8)) == CameraSettings())
        // Build 892's ⌥⌘Z never reached Mulg; saved copies of it move to the new default.
        let old = try JSONDecoder().decode(CameraSettings.self, from: Data(#"{"calibrateHotkey":"option+command+Z"}"#.utf8))
        #expect(old.calibrateHotkey == "shift+9" && Hotkey(old.calibrateHotkey) != nil)
        let chosen = try JSONDecoder().decode(CameraSettings.self, from: Data(#"{"calibrateHotkey":"f9"}"#.utf8))
        #expect(chosen.calibrateHotkey == "f9")
    }
}

/// The scanner run against this test process: a fake camera distance and its limits in ordinary
/// heap memory, found and raised the way calibration does it in a game.
@Suite("Camera memory search", .serialized)
struct CameraMemoryTests {
    final class FakeCamera {
        // Unusual values, so nothing else in the test process matches them.
        static let far: Float = 37.123_45
        static let near: Float = 3.217_89
        let block: UnsafeMutablePointer<Float>

        init() {
            block = .allocate(capacity: 64)
            block.initialize(repeating: 0, count: 64)
            block[10] = Self.near   // the nearest limit…
            block[12] = Self.far    // …and the farthest, 8 bytes later, as in a settings object
            block[40] = Self.far    // the camera distance, zoomed out
        }

        deinit { block.deallocate() }

        func zoom(out: Bool) { block[40] = out ? Self.far : Self.near }
        var distanceAddress: UInt64 { UInt64(UInt(bitPattern: block + 40)) }
        var farLimitAddress: UInt64 { UInt64(UInt(bitPattern: block + 12)) }
    }

    @Test func calibrationFindsTheDistanceAndItsLimits() throws {
        let camera = FakeCamera()
        let scan = try CameraScan(range: 1...100, limit: 50_000_000)
        camera.zoom(out: false)
        #expect(scan.keepDecreased() > 0)
        camera.zoom(out: true)
        #expect(scan.keepFarthestAgain() > 0)
        camera.zoom(out: false)
        #expect(scan.keepNearestAgain() > 0)
        let survivors = scan.survivors()
        #expect(survivors.contains { $0.address == camera.distanceAddress })

        let group = try #require(CameraCalibrationPlan.groups(survivors).first {
            $0.farthest == FakeCamera.far && $0.nearest == FakeCamera.near
        })
        let pairs = try #require(CameraMemory.pairs(farthestBits: group.farthestBits, nearestBits: group.nearestBits,
                                                    excluding: group.addresses))
        let pair = try #require(pairs.first { $0.address == camera.farLimitAddress })
        #expect(pair.offset == -8)
        // The one-pass search for several groups finds the same pair.
        let sets = CameraMemory.pairs(for: [group], excluding: group.addresses)
        #expect(sets.first??.contains { $0.address == camera.farLimitAddress && $0.offset == -8 } == true)

        // Raise, read back, find again by the saved offset, and restore.
        let raised = CameraCalibrationPlan.raisedBits(farthestBits: group.farthestBits, reach: 1.5)
        #expect(CameraMemory.swap(pair.address, expected: group.farthestBits, replacement: raised) == .swapped)
        #expect(camera.block[12] == FakeCamera.far * 1.5)
        #expect(CameraMemory.swap(pair.address, expected: group.farthestBits, replacement: raised) == .different)
        #expect(CameraMemory.swap(pair.address, expected: raised, replacement: group.farthestBits) == .swapped)
        let again = try #require(CameraMemory.pairs(farthestBits: group.farthestBits, nearestBits: group.nearestBits,
                                                    offsets: [pair.offset]))
        #expect(again.contains { $0.address == camera.farLimitAddress })
    }

    @Test func unreadableAddressesFailInsteadOfCrashing() {
        #expect(CameraMemory.read(8) == nil)
        #expect(CameraMemory.swap(8, expected: 0, replacement: 1) == .unavailable)
        #expect(CameraMemory.read(3) == nil)
    }

    @Test func tooManyValuesAreReportedNotKept() {
        #expect(throws: CameraScan.Failure.tooMany) { try CameraScan(range: 0.000_001...1e30, limit: 1) }
    }
}
