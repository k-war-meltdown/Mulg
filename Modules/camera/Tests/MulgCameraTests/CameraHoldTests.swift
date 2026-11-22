import Foundation
import Testing
import MulgContracts
@testable import MulgCamera

/// The hold engine against simulated games on real memory: a "game" thread updates a camera
/// distance every millisecond while Mulg holds it.
@Suite("Camera hold", .serialized)
struct CameraHoldTests {
    final class FakeGame: @unchecked Sendable {
        let distance = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        let derived = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        private let stopped = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        static let limit: Float = 6.5

        init() {
            distance.pointee = Self.limit
            derived.pointee = Self.limit
            stopped.pointee = false
        }

        /// `eases`: the camera eases toward its clamped target from wherever it is (holding works).
        /// Otherwise it is recomputed from the target every frame (holding cannot work).
        func run(eases: Bool) {
            Thread.detachNewThread { [self] in
                while !stopped.pointee {
                    let current = distance.pointee
                    let next = eases ? current + (Self.limit - current) * 0.1 : Self.limit
                    distance.pointee = next
                    derived.pointee = next // the camera position follows the distance
                    usleep(1_000)
                }
            }
        }

        func stop() { stopped.pointee = true; usleep(5_000) }
        var distanceAddress: UInt64 { UInt64(UInt(bitPattern: distance)) }
        var derivedAddress: UInt64 { UInt64(UInt(bitPattern: derived)) }
    }

    private func target(_ game: FakeGame, watched: Bool) -> CameraHold.Target {
        CameraHold.Target(addresses: [game.distanceAddress], farthestBits: FakeGame.limit.bitPattern,
                          raisedBits: (FakeGame.limit * 1.6).bitPattern,
                          watched: watched ? [(game.derivedAddress, FakeGame.limit.bitPattern)] : [])
    }

    @Test func holdingAnEasedCameraWorks() {
        let game = FakeGame()
        game.run(eases: true)
        defer { game.stop() }
        let hold = CameraHold()
        hold.start(target(game, watched: true), force: true)
        // Waits for the ticks rather than a fixed time: under load (the whole suite) 0.8 s gave fewer than 100.
        let deadline = ContinuousClock.now + .seconds(5)
        repeat { usleep(100_000) } while hold.statistics.ticks <= 40 && ContinuousClock.now < deadline
        let statistics = hold.stop()
        #expect(statistics.ticks > 40, "\(statistics)")
        #expect(CameraCalibrationPlan.holdWorked(statistics, watched: true))
        #expect(CameraCalibrationPlan.holdWorked(statistics, watched: false))
    }

    @Test func aCameraRecomputedEveryFrameIsDetected() {
        let game = FakeGame()
        game.run(eases: false)
        defer { game.stop() }
        let hold = CameraHold()
        hold.start(target(game, watched: true), force: true)
        usleep(800_000)
        let statistics = hold.stop()
        #expect(!CameraCalibrationPlan.holdWorked(statistics, watched: true))
    }

    @Test func zoomingInStopsExtending() {
        let game = FakeGame()
        let hold = CameraHold()
        hold.start(target(game, watched: false)) // waits for the limit, which the game is at
        // Two ticks: a throttled process sleeps about 50 ms per 4 ms tick, so wait for the write itself.
        let deadline = ContinuousClock.now + .seconds(2)
        while game.distance.pointee != FakeGame.limit * 1.6 && ContinuousClock.now < deadline { usleep(4_000) }
        #expect(game.distance.pointee == FakeGame.limit * 1.6)
        hold.playerZoomed(outward: false)
        game.distance.pointee = 3 // the player zoomed in
        usleep(50_000)
        #expect(game.distance.pointee == 3)
        hold.stop()
    }

    @Test func aNormalisedLevelIsExtendedToTheRaisedDistance() {
        let level = CameraCalibrationPlan.Group(farthestBits: Float(1).bitPattern, nearestBits: 0, addresses: [1])
        let distance = CameraCalibrationPlan.Group(farthestBits: Float(8).bitPattern, nearestBits: Float(2).bitPattern, addresses: [2])
        // Distance 2 + t × 6 should reach 8 × 1.5 = 12: t = 10 / 6.
        let held = Float(bitPattern: CameraCalibrationPlan.heldBits(level, distance: distance, reach: 1.5))
        #expect(abs(held - 10.0 / 6.0) < 0.0001)
        #expect(Float(bitPattern: CameraCalibrationPlan.heldBits(distance, distance: nil, reach: 1.5)) == 12)
    }
}

@Suite("Camera reach with Genshin's measured values")
struct GenshinValuesTests {
    @Test func easedLevelMapsOntoTheDistance() {
        // A normalised zoom level may ease to a small normal float.
        let level = CameraCalibrationPlan.Group(farthestBits: Float(1).bitPattern,
                                                nearestBits: Float(0.0001).bitPattern, addresses: [1])
        let distance = CameraCalibrationPlan.Group(farthestBits: Float(6.349727630615234).bitPattern,
                                                   nearestBits: Float(0.19827651977539062).bitPattern, addresses: [2])
        #expect(CameraCalibrationPlan.isPlausible(farthest: level.farthest, nearest: level.nearest))
        let held = Float(bitPattern: CameraCalibrationPlan.heldBits(level, distance: distance, reach: 2.3))
        // The distance this level gives: 0.198 + held × (6.35 − 0.198) = 6.35 × 2.3.
        let reached = distance.nearest + held * (distance.farthest - distance.nearest)
        #expect(abs(reached - distance.farthest * 2.3) < 0.001)
    }
}
