import Darwin
import Foundation

/// A process-lifetime lock shared by the runtime and host mutations. The kernel releases it
/// after a crash, so stale PID files never prevent a later launch.
public final class GameSessionLease: Sendable {
    public enum Failure: Error, Sendable, Equatable, LocalizedError {
        case busy, invalidIdentifier, io(Int32)
        public var errorDescription: String? {
            switch self {
            case .busy: "The game is running or another operation is updating it."
            case .invalidIdentifier: "The game's bundle identifier is invalid."
            case .io(let code): "Cannot lock the game session (system error \(code))."
            }
        }
    }
    private let descriptor: Int32
    public let bundleIdentifier: String
    private let reservationFile: URL
    public static let launchTokenEnvironmentKey = "MULG_LAUNCH_TOKEN"

    public static func isValidBundleIdentifier(_ identifier: String) -> Bool {
        !identifier.isEmpty && identifier != "." && identifier != ".." && identifier.utf8.count < 240 && identifier.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }
    }

    public init(bundleIdentifier: String, paths: ContainerPaths = .current(), launchToken: String? = nil) throws {
        guard Self.isValidBundleIdentifier(bundleIdentifier) else {
            throw Failure.invalidIdentifier
        }
        self.bundleIdentifier = bundleIdentifier
        let folder = paths.mulgStateDirectory.appendingPathComponent("Sessions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent(bundleIdentifier + ".lock")
        reservationFile = folder.appendingPathComponent(bundleIdentifier + ".launch.lock")
        let reservation = open(reservationFile.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard reservation >= 0 else { throw Failure.io(errno) }
        defer { close(reservation) }
        var handoff = false
        if flock(reservation, LOCK_SH | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK else { throw Failure.io(code) }
            var bytes = [UInt8](repeating: 0, count: 36)
            let count = pread(reservation, &bytes, bytes.count, 0)
            guard let launchToken, UUID(uuidString: launchToken) != nil, count == bytes.count,
                  String(decoding: bytes, as: UTF8.self) == launchToken else { throw Failure.busy }
            handoff = true
        }
        let fd = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.io(errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { throw Failure.busy }
            throw Failure.io(code)
        }
        if handoff {
            var claimed: UInt8 = 1
            guard pwrite(reservation, &claimed, 1, 36) == 1 else {
                let code = errno; close(fd); throw Failure.io(code)
            }
        }
        descriptor = fd
    }

    deinit { flock(descriptor, LOCK_UN); close(descriptor) }

    /// Created while the host still holds this lease. Other callers cannot mutate the bundle
    /// between releasing the host lease and the token-bearing runtime taking it.
    public func reserveLaunch() throws -> GameLaunchReservation {
        try GameLaunchReservation(file: reservationFile)
    }
}

public final class GameLaunchReservation: Sendable {
    public let token = UUID().uuidString
    private let descriptor: Int32
    public var isClaimed: Bool {
        var claimed: UInt8 = 0
        return pread(descriptor, &claimed, 1, 36) == 1 && claimed == 1
    }

    fileprivate init(file: URL) throws {
        let fd = open(file.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw GameSessionLease.Failure.io(errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno; close(fd)
            if code == EWOULDBLOCK { throw GameSessionLease.Failure.busy }
            throw GameSessionLease.Failure.io(code)
        }
        let data = Data(token.utf8)
        let written = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        guard written == data.count, ftruncate(fd, off_t(data.count)) == 0, fsync(fd) == 0 else {
            let code = errno; close(fd); throw GameSessionLease.Failure.io(code)
        }
        descriptor = fd
    }

    deinit { close(descriptor) } // The kernel also releases reservations after host failure.
}
