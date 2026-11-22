import Foundation
import MulgContracts

/// Safe mode after crashes (PLAN.md §1.5 rule 10).
///
/// A launch writes a marker counting unfinished launches; a launch that runs for 30 seconds
/// removes it. If two launches in a row never got that far, the next one starts with every
/// experimental or off-by-default module switched off, and the user is told which.
public struct SafeMode: Sendable {
    public enum Launch: Sendable, Equatable {
        case normal
        case safe(unfinishedLaunches: Int)
        case minimal(unfinishedLaunches: Int)

        public var isSafe: Bool {
            self != .normal
        }
        public var isMinimal: Bool {
            if case .minimal = self { return true }
            return false
        }
    }

    public enum Stage: String, Codable, Sendable {
        case boot, preparing, waitingForScene, activating, running, healthy, closing
    }

    public struct Record: Codable, Sendable {
        public var launchID: UUID
        public var unfinishedLaunches: Int
        public var stage: Stage
        public var module: ModuleID?
        public var runtimeVersion: String
        public var runtimeProtocol: Int
        public var enabledModules: [ModuleID]
        public var started: Date
        public var updated: Date
    }

    /// Unfinished launches that trigger safe mode.
    public static let threshold = LaunchEnvironment.recoveryThreshold
    /// How long a launch must run to count as successful.
    public static let successDelay: Duration = .seconds(30)

    public let marker: URL
    private let launchID = UUID()
    public var previousRecord: URL { marker.appendingPathExtension("last.json") }

    public init(marker: URL) {
        self.marker = marker
    }

    public init(paths: ContainerPaths, bundleIdentifier: String) {
        self.init(marker: paths.safeModeMarker(for: bundleIdentifier))
    }

    /// Unfinished launches recorded before this one.
    public func unfinishedLaunches() -> Int {
        if let record = record() { return record.stage == .healthy ? 0 : record.unfinishedLaunches }
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else {
            return 0
        }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Call once at start-up: decides the mode and records this launch as unfinished.
    public func beginLaunch(settings: GameSettings? = nil) -> Launch {
        // Successful startup breaks the consecutive-failure streak, including old healthy
        // records whose counter was not reset. Keep the journal for crash diagnostics.
        let previous = max(0, unfinishedLaunches())
        do {
            try FileManager.default.createDirectory(
                at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? Data(contentsOf: marker) {
                // The diagnostic copy must never prevent the live journal from advancing.
                // Older sandbox grants omitted this path, keeping recovery stuck on one launch.
                do { try data.writeBeside(to: previousRecord) }
                catch { MulgLog.logger(.engine).error("Previous launch not archived: \(String(describing: error), privacy: .public)") }
            }
            let record = Record(launchID: launchID, unfinishedLaunches: previous == Int.max ? previous : previous + 1,
                                stage: .boot, runtimeVersion: MulgVersion.current, runtimeProtocol: MulgVersion.runtimeProtocol,
                                enabledModules: ModuleID.allCases.filter {
                                    $0.runsInGame && (settings?.mulg.engine.isModuleEnabled($0) ?? true)
                                }, started: .now, updated: .now)
            try JSONEncoder().encode(record).writeBeside(to: marker)
        } catch {
            MulgLog.logger(.engine).error("Could not write the safe-mode marker: \(String(describing: error), privacy: .public)")
        }
        guard settings?.mulg.engine.automaticRecovery != false else { return .normal }
        if previous >= Self.threshold * 2 { return .minimal(unfinishedLaunches: previous) }
        return previous >= Self.threshold ? .safe(unfinishedLaunches: previous) : .normal
    }

    /// The previous launch's interrupted stage, for diagnostics only. It cannot
    /// identify the crashed thread or justify permanently disabling a module.
    public func interruptedModule() -> ModuleID? {
        guard let record = record(), [.preparing, .activating].contains(record.stage) else { return nil }
        return record.module
    }

    /// Persisted changes require actual attribution. Missing reports, foreign SDK
    /// frames and unmatched runtime builds yield nil. Unfinished launches still
    /// trigger temporary safe mode without changing saved feature preferences.
    public static func moduleToDisable(blamedModule: ModuleID?, settings: GameSettings) -> ModuleID? {
        guard settings.mulg.engine.automaticRecovery, let module = blamedModule,
              module.runsInGame, !module.isEssential,
              settings.mulg.engine.isModuleEnabled(module) else { return nil }
        return module
    }

    public func record() -> Record? {
        guard let data = try? Data(contentsOf: marker) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    public func stage(_ stage: Stage, module: ModuleID? = nil) {
        guard var record = record(), record.launchID == launchID else { return }
        record.stage = stage
        if stage == .healthy { record.unfinishedLaunches = 0 }
        record.module = module
        record.updated = .now
        do { try JSONEncoder().encode(record).writeBeside(to: marker) }
        catch { MulgLog.logger(.engine).error("Launch stage not saved: \(String(describing: error), privacy: .public)") }
    }

    /// Call when the launch has run long enough: clears the marker.
    public func launchSucceeded() {
        if let record = record(), record.launchID != launchID { return }
        try? FileManager.default.removeItem(at: marker)
    }
}
