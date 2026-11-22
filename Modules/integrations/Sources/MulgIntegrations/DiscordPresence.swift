import Darwin
import Foundation
import MulgContracts

/// Discord Rich Presence (settings key `discordActivity`), the same presence the old runtime set
/// through SwordRPC, over Discord's local IPC socket with plain POSIX calls instead of swift-nio.
///
/// Protocol: each frame is a little-endian opcode and payload length, then JSON. Opcode 0 is the
/// handshake, 1 a command; Discord answers the handshake with READY before it accepts commands.
enum DiscordPresence {
    static let handshake: UInt32 = 0
    static let command: UInt32 = 1

    /// Connects in the background and sets the presence. Nothing happens without an application
    /// ID or when Discord is not running.
    // ponytail: no default Discord application yet, so presence needs the user's own ID; register
    // one for Mulg to turn it on for everyone. No reconnect if Discord starts after the game.
    static func start(_ custom: DiscordActivitySettings, bundleIdentifier: String) {
        guard custom.enable, !custom.applicationID.isEmpty else { return }
        let info = Bundle.main.infoDictionary
        let name = info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String ?? ""
        let started = Date()
        Task.detached(priority: .background) {
            var storeArtwork: String?
            if custom.image.isEmpty {
                storeArtwork = await artwork(bundleIdentifier: bundleIdentifier)
            }
            let presence = activity(custom, gameName: name, artwork: storeArtwork, start: started)
            // ponytail: the socket stays open for the game's lifetime; Discord clears the
            // presence when the game quits and the socket closes.
            guard let socket = temporaryDirectories().lazy.compactMap({ connect(temporaryDirectory: $0) }).first else { return }
            guard send(frame(handshake, ["v": 1, "client_id": custom.applicationID]), to: socket),
                  readFrameOpcode(socket) == command else {
                close(socket)
                return
            }
            _ = send(frame(command, ["cmd": "SET_ACTIVITY", "nonce": UUID().uuidString,
                                     "args": ["pid": Int(getpid()), "activity": presence]]), to: socket)
        }
    }

    /// The activity JSON, as the old runtime built it.
    static func activity(_ custom: DiscordActivitySettings, gameName: String, artwork: String?,
                         start: Date) -> [String: Any] {
        let powered = "Powered by Mulg"
        // Discord refuses one-character texts, so they get a trailing space.
        func padded(_ text: String) -> String { text.count == 1 ? text + " " : text }
        var assets: [String: String] = [:]
        var state = powered
        if !custom.state.isEmpty {
            state = padded(custom.state)
            assets["small_text"] = powered
            assets["large_text"] = powered
        }
        if let image = custom.image.isEmpty ? artwork : Optional(custom.image) {
            assets["large_image"] = image
            assets["large_text"] = nil
        }
        return ["details": custom.details.isEmpty ? "Playing \(gameName)" : padded(custom.details),
                "state": state,
                "assets": assets,
                "timestamps": ["start": Int(start.timeIntervalSince1970 * 1000)]]
    }

    static func frame(_ opcode: UInt32, _ json: [String: Any]) -> Data {
        let payload = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        var data = Data()
        for value in [opcode, UInt32(payload.count)] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data + payload
    }

    /// The game's App Store artwork, used as the large image when none is set.
    private static func artwork(bundleIdentifier: String) async -> String? {
        guard let url = URL(string: "https://itunes.apple.com/lookup?bundleId=\(bundleIdentifier)"),
              let data = try? await URLSession.shared.data(from: url).0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }
        return results.first?["artworkUrl512"] as? String
    }

    /// The game's own temporary folder is inside its container; Discord listens in the user's real
    /// one, which `TMPDIR` or `confstr` give when the container hides it.
    private static func temporaryDirectories() -> [String] {
        var bytes = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &bytes, bytes.count)
        let user = length > 0 ? String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
        return [FileManager.default.temporaryDirectory.path, ProcessInfo.processInfo.environment["TMPDIR"], user]
            .compactMap { $0 }
    }

    /// Discord listens on the first free of `discord-ipc-0` to `-9` in the temporary folder.
    private static func connect(temporaryDirectory: String) -> Int32? {
        for port in 0..<10 {
            let path = Array((temporaryDirectory + "/discord-ipc-\(port)").utf8)
            var address = sockaddr_un()
            guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
            let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard socket >= 0 else { return nil }
            // A write after Discord closed the socket must fail, not kill the game with SIGPIPE.
            var on: Int32 = 1
            setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // A Discord that never answers must not hold a concurrency thread for the whole session.
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if connected == 0 { return socket }
            close(socket)
        }
        return nil
    }

    private static func send(_ data: Data, to socket: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(socket, buffer.baseAddress! + offset, buffer.count - offset)
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    /// Reads one frame and returns its opcode (READY arrives as a command frame, a refused
    /// handshake as opcode 2, close).
    private static func readFrameOpcode(_ socket: Int32) -> UInt32? {
        func read(_ count: Int) -> [UInt8]? {
            var bytes = [UInt8](repeating: 0, count: count)
            var offset = 0
            while offset < count {
                let got = bytes.withUnsafeMutableBytes { Darwin.read(socket, $0.baseAddress! + offset, count - offset) }
                guard got > 0 else { return nil }
                offset += got
            }
            return bytes
        }
        guard let header = read(8) else { return nil }
        let word = { (at: Int) in header[at..<at + 4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
        // A garbled length must not allocate gigabytes.
        guard word(4) < 1 << 20, read(Int(word(4))) != nil else { return nil }
        return word(0)
    }
}
