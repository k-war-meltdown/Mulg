// Host-side module: the Mulg app is a native macOS app, never Mac Catalyst.
#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import CryptoKit
import MulgContracts

/// Runs a command-line tool and returns its output (PLAN.md §12.1 #8): `executableURL` and
/// `run()`, and a non-zero exit is an error. Replaces upstream `Shell.swift`.
public enum Command {
    public struct Failure: Error, Sendable, Equatable {
        public let executable: String
        public let status: Int32
        public let output: String
    }

    // ponytail: synchronous; the tools it runs (codesign, ditto, csrutil) finish quickly.
    // Make it async with a readability handler if a long-running tool ever goes through here.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String], directory: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(executable: executable, status: process.terminationStatus, output: output)
        }
        return output
    }
}

/// Puts the runtime where games load it from (replaces upstream `MulgKit.installOnSystem`).
public enum RuntimeInstaller {
    public enum ValidationFailure: Error, CustomStringConvertible {
        case wrongManifest(String), wrongPlatform(String), installedCopyDiffers
        public var description: String {
            switch self {
            case .wrongManifest(let path): "Runtime metadata does not match this app: \(path)"
            case .wrongPlatform(let path): "Runtime artifact has the wrong platform or architecture: \(path)"
            case .installedCopyDiffers: "Installed runtime differs from the verified bundled runtime"
            }
        }
    }

    public static func validatePair(framework: URL, bridge: URL) throws {
        let expected = RuntimeManifest()
        for manifest in [RuntimeManifest.frameworkURL(framework),
                         bridge.appendingPathComponent("Contents/Resources/" + RuntimeManifest.fileName)] {
            guard try RuntimeManifest.read(at: manifest) == expected else {
                throw ValidationFailure.wrongManifest(manifest.path)
            }
        }
        try validateBinary(framework.appendingPathComponent("MulgRuntime"), platform: 6)
        try validateBinary(bridge.appendingPathComponent("Contents/MacOS/MulgBridge"), platform: 1)
    }

    /// No x86 fallback: both artifacts must contain ARM64 code for their own platform.
    public static func validateBinary(_ url: URL, platform: UInt32) throws {
        let data = try MachOBinary.arm64Slice(of: Data(contentsOf: url, options: .alwaysMapped))
        let builds = try MachOBinary.loadCommands(in: data).filter { $0.command == 0x32 }
        guard !builds.isEmpty, builds.allSatisfy({ command in
            guard command.size >= 24 else { return false }
            let offset = command.offset + 8
            return data[offset] == UInt8(platform) && data[offset + 1] == 0
                && data[offset + 2] == 0 && data[offset + 3] == 0
        }) else { throw ValidationFailure.wrongPlatform(url.path) }
    }

    public static func validateInstalled(_ installed: URL, bundled: URL, bridge: URL) throws {
        try validatePair(framework: installed, bridge: bridge)
        let actual = try Data(contentsOf: installed.appendingPathComponent("MulgRuntime"), options: .alwaysMapped)
        let expected = try Data(contentsOf: bundled.appendingPathComponent("MulgRuntime"), options: .alwaysMapped)
        guard SHA256.hash(data: actual) == SHA256.hash(data: expected) else {
            throw ValidationFailure.installedCopyDiffers
        }
    }
    /// `~/Library/Frameworks/MulgRuntime.framework`
    public static func installedFramework(home: URL = ContainerPaths.realHomeDirectory()) -> URL {
        URL(fileURLWithPath: GameInstaller.runtimePath(home: home)).deletingLastPathComponent()
    }

    /// Content-addressed versions are immutable. An installed game keeps its old loader path
    /// until its executable and bridge have both been migrated and verified.
    public static func versionedFramework(bundled: URL, home: URL = ContainerPaths.realHomeDirectory()) throws -> URL {
        let manifest = try RuntimeManifest.read(at: RuntimeManifest.frameworkURL(bundled))
        let bytes = try Data(contentsOf: bundled.appendingPathComponent("MulgRuntime"), options: .alwaysMapped)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let version = "p\(manifest.runtimeProtocol)-\(digest)"
        return home.appendingPathComponent("Library/Frameworks/MulgRuntimeVersions/" + version + "/MulgRuntime.framework", isDirectory: true)
    }

    public static func installVersion(bundled: URL, bridge: URL,
                                      home: URL = ContainerPaths.realHomeDirectory()) throws -> URL {
        try validatePair(framework: bundled, bridge: bridge)
        let target = try versionedFramework(bundled: bundled, home: home)
        if FileManager.default.fileExists(atPath: target.path) {
            try validateInstalled(target, bundled: bundled, bridge: bridge)
        } else {
            try replace(target, with: bundled) { try validatePair(framework: $0, bridge: bridge) }
        }
        return target
    }

    public static func isRuntimeLibrary(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        return url.lastPathComponent == "MulgRuntime"
            && url.deletingLastPathComponent().lastPathComponent == "MulgRuntime.framework"
    }

    /// `replace`, unless the installed copy already has the bundled contents (every app start
    /// asks; usually nothing changed).
    public static func replaceIfDifferent(_ target: URL, with bundled: URL) throws {
        if FileManager.default.contentsEqual(atPath: target.path, andPath: bundled.path) { return }
        try replace(target, with: bundled)
    }

    /// Deletes installed runtime versions no game uses: everything in `MulgRuntimeVersions` except
    /// `keeping` (version folder names, such as "p5-<digest>"). The caller lists what the games
    /// link; when it cannot read a game, it must not call this.
    @discardableResult
    public static func pruneVersions(keeping: Set<String>, home: URL = ContainerPaths.realHomeDirectory()) -> [String] {
        let folder = home.appendingPathComponent("Library/Frameworks/MulgRuntimeVersions", isDirectory: true)
        let files = FileManager.default
        var removed: [String] = []
        for name in (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
        where name.hasPrefix("p") && !keeping.contains(name) {
            if (try? files.removeItem(at: folder.appendingPathComponent(name))) != nil { removed.append(name) }
        }
        return removed
    }

    /// The version folder name in a runtime load path ".../MulgRuntimeVersions/<name>/MulgRuntime.framework/...".
    public static func versionName(inLoadPath path: String) -> String? {
        let parts = path.split(separator: "/")
        guard let index = parts.firstIndex(of: "MulgRuntimeVersions"), index + 1 < parts.count else { return nil }
        return String(parts[index + 1])
    }

    /// Copies the framework bundled with the app over the installed one. The old copy is
    /// replaced in one step, so a game starting meanwhile never sees half a framework.
    public static func install(bundled: URL, home: URL = ContainerPaths.realHomeDirectory()) throws {
        try replace(installedFramework(home: home), with: bundled)
    }

    /// Copies `bundled` next to `target` first, then swaps it in. If the copy fails, the old
    /// framework stays; a game starting meanwhile finds the old one or the new one, never neither.
    public static func replace(_ target: URL, with bundled: URL, verify: (URL) throws -> Void = { _ in }) throws {
        let files = FileManager.default
        try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent)-\(UUID().uuidString)")
        // Gone after a successful swap; a failed copy leaves nothing behind.
        defer { try? files.removeItem(at: staging) }
        try files.copyItem(at: bundled, to: staging)
        try verify(staging)
        if files.fileExists(atPath: target.path) {
            _ = try files.replaceItemAt(target, withItemAt: staging)
        } else {
            try files.moveItem(at: staging, to: target)
        }
    }
}

/// Game launches and exits from macOS's own notifications (PLAN.md §12.1 #5), instead of
/// checking once a second whether a game still runs.
public enum GameWatcher {
    /// Process creation alone does not confirm runtime handoff. Host UI reacts to this event.
    public static let launchAcceptedNotification = Notification.Name("io.mulg.game.launchAccepted")
    @MainActor public static func launchAccepted(_ identifier: String, processIdentifier: pid_t) {
        NotificationCenter.default.post(name: launchAcceptedNotification, object: nil,
            userInfo: ["bundleIdentifier": identifier, "processIdentifier": processIdentifier])
    }
    @MainActor private static var launching: Set<String> = []
    @MainActor private static var monitored: Set<pid_t> = []

    @MainActor public static func beginLaunch(_ identifier: String) -> Bool {
        launching.insert(identifier).inserted
    }
    @MainActor public static func endLaunch(_ identifier: String) { launching.remove(identifier) }
    @MainActor public static func beginMonitoring(_ pid: pid_t) -> Bool { monitored.insert(pid).inserted }
    @MainActor public static func endMonitoring(_ pid: pid_t) { monitored.remove(pid) }
    public struct Event: Sendable, Equatable {
        public let bundleIdentifier: String?
        public let processIdentifier: pid_t
        public let launched: Bool
    }

    /// Every app launch and exit until the stream is dropped.
    public static func events(center: NotificationCenter = NSWorkspace.shared.notificationCenter) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let observers = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map { name in
                center.addObserver(forName: name, object: nil, queue: nil) { note in
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    continuation.yield(Event(bundleIdentifier: app?.bundleIdentifier,
                                             processIdentifier: app?.processIdentifier ?? 0,
                                             launched: name == NSWorkspace.didLaunchApplicationNotification))
                }
            }
            nonisolated(unsafe) let tokens = observers
            continuation.onTermination = { _ in tokens.forEach(center.removeObserver) }
        }
    }

    /// A live (not yet terminated) process of the game, if any.
    public static func process(_ bundleIdentifier: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first { !$0.isTerminated }
    }

    public static func isRunning(_ bundleIdentifier: String) -> Bool {
        process(bundleIdentifier) != nil
    }

    // MARK: Run state

    /// What the Mulg app shows for a game whose process exists.
    public enum RunState: Sendable, Equatable {
        case running
        /// The window was closed or Quit was chosen: the game is saving and will exit (up to the
        /// shutdown deadline). It has no window any more, so "Bring forward" would do nothing.
        case closing
    }

    /// The run state of every running app, by bundle identifier. `exitedProcess` is left out: in a
    /// termination notification it may still be listed for a moment.
    @MainActor public static func runStates(exitedProcess: pid_t? = nil,
                                           paths: ContainerPaths = .current()) -> [String: RunState] {
        let markers = closingMarkers(paths)
        var states: [String: RunState] = [:]
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated && app.processIdentifier != exitedProcess {
            guard let identifier = app.bundleIdentifier else { continue }
            // Only a record written by this process counts: one from before it started is old.
            let closing = markers[identifier].map { stamp in
                (processStart(app.processIdentifier) ?? app.launchDate).map { stamp >= $0 } ?? false
            } ?? false
            // Two copies (one closing, one new): the new one decides.
            if states[identifier] != .running { states[identifier] = closing ? .closing : .running }
        }
        return states
    }

    /// When the process started, from the kernel (`launchDate` is nil for some processes).
    private static func processStart(_ pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1e6)
    }

    /// Games whose runtime recorded that they are closing (the safe-mode journal's `closing`
    /// stage, written when the window closes or Quit is chosen), with the time it was recorded.
    private static func closingMarkers(_ paths: ContainerPaths) -> [String: Date] {
        let folder = paths.safeModeMarker(for: "x").deletingLastPathComponent()
        let suffix = ".launches"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [:] }
        var markers: [String: Date] = [:]
        for name in names where name.hasSuffix(suffix) {
            let file = folder.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: file), data.count < 65_536,
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  record["stage"] as? String == "closing" else { continue }
            let stamp = (record["updated"] as? NSNumber).map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) } ?? .distantPast
            markers[String(name.dropLast(suffix.count))] = stamp
        }
        return markers
    }

    /// Run states now, then whenever an app launches or exits, and every second in between, so a
    /// missed or early notification can never leave a game shown as running (or not) for long.
    /// Yields only changes.
    @MainActor public static func runStateUpdates() -> AsyncStream<[String: RunState]> {
        AsyncStream { continuation in
            let box = RunStateBox(continuation)
            box.publish()
            let task = Task { @MainActor in
                let wake = Task { @MainActor in
                    for await event in events() {
                        box.publish(exitedProcess: event.launched ? nil : event.processIdentifier)
                    }
                }
                defer { wake.cancel() }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    box.publish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @MainActor private final class RunStateBox {
        private let continuation: AsyncStream<[String: RunState]>.Continuation
        private var last: [String: RunState]?
        init(_ continuation: AsyncStream<[String: RunState]>.Continuation) { self.continuation = continuation }
        func publish(exitedProcess: pid_t? = nil) {
            let states = GameWatcher.runStates(exitedProcess: exitedProcess)
            guard states != last else { return }
            last = states
            continuation.yield(states)
        }
    }

    /// Returns once no copy of the game runs any more.
    public static func waitForExit(of bundleIdentifier: String) async {
        let stream = events()  // subscribe before checking, so an exit in between is not missed
        guard isRunning(bundleIdentifier) else { return }
        for await event in stream where !event.launched && event.bundleIdentifier == bundleIdentifier {
            if !isRunning(bundleIdentifier) { return }
        }
    }
}

/// MulgSign lets games with restricted entitlements run by turning off Apple Mobile File
/// Integrity. That lowers system security, so the app never asks for or holds the admin
/// password (PLAN.md §12.1 #6–7): it shows the command, the user runs it in Terminal and
/// can undo it the same way.
public enum MulgSign {
    public static let bootArguments = ["amfi_get_out_of_my_way=0x1", "ipc_control_port_options=0"]

    /// True when the running system was booted with AMFI off.
    public static func isActive(kernelBootArguments: String) -> Bool {
        let words = Set(kernelBootArguments.split(whereSeparator: \.isWhitespace))
        return words.contains("amfi_get_out_of_my_way=1") || words.contains("amfi_get_out_of_my_way=0x1")
    }

    /// MulgSign needs System Integrity Protection off, which only Recovery can change.
    public static func isSIPDisabled(csrutilStatus: String) -> Bool {
        csrutilStatus.contains("disabled") || csrutilStatus.contains("unknown")
    }

    /// Adds MulgSign's arguments to the ones already set, keeping the user's own.
    public static func enableCommand(currentBootArguments: String) -> String {
        let kept = others(in: currentBootArguments)
        return "sudo /usr/sbin/nvram boot-args=\(shellQuote((kept + bootArguments).joined(separator: " ")))"
    }

    /// Removes only MulgSign's arguments again.
    public static func disableCommand(currentBootArguments: String) -> String {
        let kept = others(in: currentBootArguments)
        return kept.isEmpty ? "sudo /usr/sbin/nvram -d boot-args"
            : "sudo /usr/sbin/nvram boot-args=\(shellQuote(kept.joined(separator: " ")))"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func others(in arguments: String) -> [String] {
        arguments.split(whereSeparator: \.isWhitespace).map(String.init).filter { word in
            !word.hasPrefix("amfi_get_out_of_my_way=") && !word.hasPrefix("ipc_control_port_options=")
        }
    }

    /// The current state of this Mac.
    public static func status() -> (sipDisabled: Bool, active: Bool, bootArguments: String) {
        let csr = (try? Command.run("/usr/bin/csrutil", ["status"])) ?? ""
        let kernel = (try? Command.run("/usr/sbin/sysctl", ["-n", "kern.bootargs"])) ?? ""
        // `nvram boot-args` prints "boot-args<tab>value"; it fails when none are set.
        let stored = (try? Command.run("/usr/sbin/nvram", ["boot-args"])) ?? ""
        let value = stored.split(separator: "\t", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        return (isSIPDisabled(csrutilStatus: csr), isActive(kernelBootArguments: kernel),
                value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
#endif
