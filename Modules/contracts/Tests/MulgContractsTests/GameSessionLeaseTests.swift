import Foundation
import Testing
@testable import MulgContracts

@Suite("Process session leases")
struct GameSessionLeaseTests {
    @Test func launchReservationProtectsTheHandoffAndRequiresTheToken() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ContainerPaths(home: root)
        var host: GameSessionLease? = try GameSessionLease(bundleIdentifier: "game.handoff", paths: paths)
        var reservation: GameLaunchReservation? = try #require(host).reserveLaunch()
        let token = try #require(reservation).token
        host = nil
        #expect(throws: GameSessionLease.Failure.busy) { try GameSessionLease(bundleIdentifier: "game.handoff", paths: paths) }
        #expect(throws: GameSessionLease.Failure.busy) {
            try GameSessionLease(bundleIdentifier: "game.handoff", paths: paths, launchToken: UUID().uuidString)
        }
        var runtime: GameSessionLease? = try GameSessionLease(bundleIdentifier: "game.handoff", paths: paths, launchToken: token)
        #expect(reservation?.isClaimed == true)
        reservation = nil
        #expect(throws: GameSessionLease.Failure.busy) { try GameSessionLease(bundleIdentifier: "game.handoff", paths: paths) }
        withExtendedLifetime(runtime) {}
        runtime = nil
        let next = try GameSessionLease(bundleIdentifier: "game.handoff", paths: paths)
        withExtendedLifetime(next) {}
    }

    @Test func abandonedLaunchReservationReleasesAndDoesNotLeaveAStaleLock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ContainerPaths(home: root)
        var host: GameSessionLease? = try GameSessionLease(bundleIdentifier: "game.aborted", paths: paths)
        var reservation: GameLaunchReservation? = try #require(host).reserveLaunch()
        #expect(reservation?.isClaimed == false)
        host = nil
        reservation = nil
        let next = try GameSessionLease(bundleIdentifier: "game.aborted", paths: paths)
        withExtendedLifetime(next) {}
    }
    @Test func exclusiveLeaseReleasesWithoutAStalePIDFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ContainerPaths(home: root)
        var lease: GameSessionLease? = try GameSessionLease(bundleIdentifier: "game.example", paths: paths)
        #expect(throws: GameSessionLease.Failure.busy) { try GameSessionLease(bundleIdentifier: "game.example", paths: paths) }
        withExtendedLifetime(lease) {}
        lease = nil
        let next = try GameSessionLease(bundleIdentifier: "game.example", paths: paths)
        withExtendedLifetime(next) {}
        #expect(throws: GameSessionLease.Failure.invalidIdentifier) { try GameSessionLease(bundleIdentifier: "../escape", paths: paths) }
    }
}
