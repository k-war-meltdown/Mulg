import Foundation
import MulgContracts
import MulgEngine
import os

/// Camera reach in the running game: raises the calibrated zoom limit, keeps it raised, and
/// reports what it is doing to the app.
///
/// Two ways to raise the limit, both found by calibration (CameraReachController+Calibration):
/// - limit pairs: the game keeps its farthest and nearest zoom distances side by side in memory;
///   the farthest is replaced. Saved per game and found again by value after every launch.
/// - hold: when a game's limits are not in memory, the camera distance itself is pushed past the
///   limit each time the player reaches it. Works for this session only.
@MainActor
final class CameraReachController {
    let context: ModuleContext
    let logger: Logger
    private(set) var settings: CameraSettings
    var calibration: CameraCalibration?
    private var report: CameraReachReport

    /// Limits raised by pair: the addresses of the farthest limits, the game's value and the raised one.
    struct RaisedPairs: Sendable {
        var addresses: [UInt64]
        let farthestMasked: UInt32
        var raisedBits: UInt32
        var farthestBits: UInt32 { farthestMasked ^ CameraCalibration.mask }
    }

    /// Distances held past the limit while the player is zoomed all the way out (`holdEngine`).
    struct Hold: Sendable {
        let addresses: [UInt64]
        let farthestMasked: UInt32
        var raisedBits: UInt32
        var farthestBits: UInt32 { farthestMasked ^ CameraCalibration.mask }
    }

    enum Applied: Sendable {
        case none
        case pairs(RaisedPairs)
        case hold(Hold)
    }

    /// Changing this invalidates any check still running in the background (`appliedGeneration`).
    var applied: Applied = .none { didSet { appliedGeneration &+= 1 } }
    /// Holds the distance in hold mode; also runs the hold trials of a calibration.
    var holdEngine: CameraHold?
    /// The calibration under way, or the last one (camera-calibration.json).
    var calibrationReport: CalibrationReport?
    private(set) var appliedGeneration = 0
    private var keeper: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var searchAttempt = 0
    private var searchGeneration = 0
    private var notFoundShown = false

    // Calibration (CameraReachController+Calibration).
    enum CalibrationState: Equatable {
        case idle
        case waiting(CameraCalibrationPlan.Step)
        case working(CameraCalibrationPlan.Step)
        case checking
    }
    var calibrationState: CalibrationState = .idle
    var scan: CameraScan?
    var calibrationGeneration = 0
    var calibrationTask: Task<Void, Never>?
    var zoomTask: Task<Void, Never>?
    /// Mulg zooms the camera itself during this calibration (the controls module can pinch).
    var automaticCalibration = false
    /// When the hotkey was last pressed during a calibration (two quick presses cancel).
    var lastCalibrationPress: ContinuousClock.Instant?
    var trialWrites: [UInt64] = []
    /// The limit a trial raised (masked game value, raised value), to undo it.
    var trialLimits: (farthestMasked: UInt32, raised: UInt32)?

    var calibrationFile: URL { context.paths.cameraCalibrationFile(for: context.bundleIdentifier) }

    init(context: ModuleContext) {
        self.context = context
        logger = context.logger(for: .camera)
        settings = context.settings.mulg.camera
        report = CameraReachReport(processIdentifier: ProcessInfo.processInfo.processIdentifier)
        calibration = CameraCalibration.load(from: calibrationFile)
    }

    // MARK: Start, stop and settings

    func start() {
        guard settings.extendedReach else { setReport(.off, "Camera reach is off."); return }
        guard calibration != nil else {
            // Never starts by itself (a loading screen or menu would make it fail): the player presses the key.
            setReport(.notCalibrated, "Not set up for this game yet. In the open world, press \(hotkeyText) once.")
            context.notices.showImportant(Notice("Camera reach is on", lines: [
                "To set it up, stand in the open world and press \(hotkeyText) once."
            ], duration: .seconds(6)))
            return
        }
        scheduleSearch(restart: true)
    }

    func apply(_ new: CameraSettings) {
        let old = settings
        settings = new
        if old.extendedReach != new.extendedReach {
            if new.extendedReach {
                start()
            } else {
                cancelCalibration(notice: nil)
                stopSearching()
                restoreGameLimits()
                setReport(.off, "Camera reach is off.")
            }
        } else if new.extendedReach, old.reach != new.reach {
            changeReach(to: new.reach)
        }
    }

    /// The game is closing: stop all background work. The game's memory goes with it.
    func stop() {
        holdEngine?.stop()
        CameraCrashGuard.clear(context)
        cancelCalibration(notice: nil)
        stopSearching()
        keeper?.cancel()
        keeper = nil
    }

    /// Mulg's first calibration step holds a large scratch buffer; give it back under memory pressure.
    func memoryPressure() {
        guard scan != nil, case .waiting = calibrationState else { return }
        cancelCalibration(notice: Notice("Camera reach calibration stopped", lines: [
            "macOS is short of memory. Close other apps and try again."
        ], style: .warning))
    }

    var hotkeyText: String { Hotkey(settings.calibrateHotkey)?.description ?? settings.calibrateHotkey }

    func raisedBits(_ farthestBits: UInt32) -> UInt32 {
        CameraCalibrationPlan.raisedBits(farthestBits: farthestBits, reach: settings.reach)
    }

    // MARK: Finding saved limits after a launch

    /// Looks for the calibrated limit pairs, retrying on `searchDelays` until found.
    func scheduleSearch(restart: Bool) {
        guard settings.extendedReach, calibration != nil, calibrationState == .idle else { return }
        if restart { searchAttempt = 0; notFoundShown = false }
        searchTask?.cancel()
        let delays = CameraCalibrationPlan.searchDelays
        guard searchAttempt < delays.count else {
            setReport(.notFound, "The calibrated zoom limit was not found in this game version. Press \(hotkeyText) to calibrate again.")
            if !notFoundShown {
                notFoundShown = true
                context.notices.showImportant(Notice("Camera reach not applied", lines: [
                    "The game's zoom limit was not where calibration found it (game updated?).",
                    "Press \(hotkeyText) to calibrate again."
                ], style: .warning, duration: .seconds(8)))
            }
            return
        }
        setReport(.searching, "Looking for the calibrated zoom limit…")
        let delay = delays[searchAttempt]
        searchAttempt += 1
        searchGeneration += 1
        let generation = searchGeneration
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.search(generation: generation)
        }
    }

    private func stopSearching() {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration += 1
    }

    private func search(generation: Int) {
        guard generation == searchGeneration, settings.extendedReach, let calibration, calibrationState == .idle else { return }
        let far = calibration.farthestBits, near = calibration.nearestBits
        let offsets = calibration.offsets.map(Int32.init)
        CameraMemory.queue.async { [weak self] in
            var pairs = CameraMemory.pairs(farthestBits: far, nearestBits: near, offsets: offsets)
            // A game update can move the limits within the camera settings without changing them:
            // look anywhere beside each farthest limit before asking for a new calibration.
            if pairs?.isEmpty == true { pairs = CameraMemory.pairs(farthestBits: far, nearestBits: near) }
            let found = pairs
            Task { @MainActor [weak self] in self?.searched(found, generation: generation) }
        }
    }

    private func searched(_ pairs: [CameraMemory.Pair]?, generation: Int) {
        guard generation == searchGeneration, settings.extendedReach, let calibration, calibrationState == .idle else { return }
        guard let pairs, CameraCalibrationPlan.acceptsSearch(found: pairs.count, calibrated: calibration.pairs) else {
            if pairs == nil { logger.notice("Camera reach: the calibrated limits are too common in memory; not applied") }
            scheduleSearch(restart: false)
            return
        }
        let far = calibration.farthestBits
        let raised = raisedBits(far)
        let written = pairs.map(\.address).filter {
            CameraMemory.swap($0, expected: far, replacement: raised) == .swapped
        }
        guard !written.isEmpty else { scheduleSearch(restart: false); return }
        let offsets = CameraCalibrationPlan.offsets(pairs.filter { written.contains($0.address) })
        if offsets != calibration.offsets {
            var moved = calibration
            moved.offsets = offsets
            moved.gameVersion = Self.gameVersion
            save(moved)
            logger.notice("Camera reach: the game moved its zoom limits; calibration updated")
        }
        applied = .pairs(RaisedPairs(addresses: written, farthestMasked: far ^ CameraCalibration.mask, raisedBits: raised))
        logger.notice("Camera reach: raised \(written.count, privacy: .public) zoom limit(s)")
        appliedReport()
        startKeeper()
    }

    // MARK: Keeping limits raised

    /// Checks the raised values every 2 s (pairs) or 100 ms (hold, which follows the player's zoom).
    /// The reads and writes run on a background thread: in Unity games the main thread runs the
    /// game loop, so nothing here may take time from it.
    func startKeeper() {
        keeper?.cancel()
        keeper = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.keeperInterval else { return }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                let snapshot = self.applied, generation = self.appliedGeneration
                let checked = await Self.check(snapshot)
                guard !Task.isCancelled else { return }
                self.keepResult(checked, generation: generation)
            }
        }
    }

    private var keeperInterval: Duration? {
        switch applied {
        case .pairs: .seconds(2)
        case .hold, .none: nil // Hold has its own thread (CameraHold).
        }
    }

    private nonisolated static func check(_ applied: Applied) async -> Applied {
        await withCheckedContinuation { continuation in
            CameraMemory.keeperQueue.async { continuation.resume(returning: checkNow(applied)) }
        }
    }

    /// One check of the raised values. Returns `.none` when every raised limit is gone.
    private nonisolated static func checkNow(_ applied: Applied) -> Applied {
        switch applied {
        case .none:
            return .none
        case .pairs(var pairs):
            let far = pairs.farthestBits
            pairs.addresses = pairs.addresses.filter { address in
                guard let value = CameraMemory.read(address) else { return false }
                if value == pairs.raisedBits { return true }
                // The game reloaded its camera settings: raise again.
                return value == far && CameraMemory.swap(address, expected: far, replacement: pairs.raisedBits) == .swapped
            }
            return pairs.addresses.isEmpty ? .none : .pairs(pairs)
        case .hold:
            return applied // CameraHold keeps it.
        }
    }

    private func keepResult(_ checked: Applied, generation: Int) {
        // Switched off, re-calibrated or the reach changed while the check ran: its result is stale.
        guard generation == appliedGeneration else { return }
        if case .none = checked, case .pairs = applied {
            // The settings object is gone (new scene, relogin): find it again.
            applied = .none
            keeper?.cancel()
            logger.notice("Camera reach: raised limits went away; searching again")
            scheduleSearch(restart: true)
            return
        }
        applied = checked
    }

    private func changeReach(to reach: Double) {
        let swaps: [(UInt64, UInt32, UInt32)]
        switch applied {
        case .none:
            return
        case .pairs(var pairs):
            let new = raisedBits(pairs.farthestBits)
            swaps = pairs.addresses.map { ($0, pairs.raisedBits, new) }
            pairs.raisedBits = new
            applied = .pairs(pairs)
        case .hold(var hold):
            let new = raisedBits(hold.farthestBits)
            swaps = hold.addresses.map { ($0, hold.raisedBits, new) }
            hold.raisedBits = new
            holdEngine?.setRaised(new)
            applied = .hold(hold)
        }
        Self.perform(swaps)
        appliedReport()
    }

    /// Puts the game's own limits back (Camera reach switched off, or before calibrating).
    func restoreGameLimits() {
        keeper?.cancel()
        keeper = nil
        switch applied {
        case .none:
            return
        case .pairs(let pairs):
            Self.perform(pairs.addresses.map { ($0, pairs.raisedBits, pairs.farthestBits) })
        case .hold(let hold):
            holdEngine?.stop()
            holdEngine = nil
            Self.perform(hold.addresses.map { ($0, hold.raisedBits, hold.farthestBits) })
        }
        applied = .none
        clearCrashMarkerIfUnchanged()
    }

    /// Swaps (address, expected, replacement) on the keeper's queue, after any check still running
    /// there, so a check that started before cannot raise a limit again after it was restored.
    private static func perform(_ swaps: [(UInt64, UInt32, UInt32)]) {
        guard !swaps.isEmpty else { return }
        let work = swaps.map { CameraMemory.Swap(address: $0.0, expected: $0.1, replacement: $0.2) }
        CameraMemory.keeperQueue.async {
            for swap in work { _ = CameraMemory.swap(swap.address, expected: swap.expected, replacement: swap.replacement) }
        }
    }

    /// No limit raised, no trial written and nothing held: a crash from now on is not camera reach's.
    func clearCrashMarkerIfUnchanged() {
        guard case .none = applied, trialWrites.isEmpty, holdEngine == nil else { return }
        CameraCrashGuard.clear(context)
    }

    // MARK: Report

    func setReport(_ state: CameraReachReport.State, _ message: String, gameLimit: Float = 0, raisedLimit: Float = 0) {
        if state == .applied { CameraCrashGuard.markActive(context) }
        report.state = state
        report.message = message
        report.gameLimit = Double(gameLimit)
        report.raisedLimit = Double(raisedLimit)
        report.updated = .now
        ReportWriter.shared.write(report, to: context.paths.diagnosticsDirectory(for: context.bundleIdentifier)
            .appendingPathComponent(CameraReachReport.fileName))
    }

    func appliedReport() {
        let percent = Int(((settings.reach - 1) * 100).rounded())
        switch applied {
        case .none:
            break
        case .pairs(let pairs):
            setReport(.applied, "Zoom limit raised \(percent) % (\(pairs.addresses.count) camera setting(s)).",
                      gameLimit: Float(bitPattern: pairs.farthestBits), raisedLimit: Float(bitPattern: pairs.raisedBits))
        case .hold(let hold):
            setReport(.applied, "Zoom limit raised \(percent) % for this session (this game keeps its limit in code; calibrate again after a restart).",
                      gameLimit: Float(bitPattern: hold.farthestBits), raisedLimit: Float(bitPattern: hold.raisedBits))
        }
    }
}

extension CameraReachController {
    /// Keeps `value` as this game's calibration, in memory and on disk.
    func save(_ value: CameraCalibration) {
        calibration = value
        do {
            try FileManager.default.createDirectory(at: calibrationFile.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(value).writeBeside(to: calibrationFile)
        } catch {
            logger.error("Camera reach calibration not saved: \(String(describing: error), privacy: .public)")
        }
    }
}

extension CameraReachController {
    /// The player zoomed (scroll wheel): hold mode stops extending when they zoom in.
    func playerZoomed(outward: Bool) {
        holdEngine?.playerZoomed(outward: outward)
    }
}

extension CameraReachController {
    func writeCalibrationReport() {
        guard let calibrationReport else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        ReportWriter.shared.write(calibrationReport, to: context.paths.diagnosticsDirectory(for: context.bundleIdentifier)
            .appendingPathComponent(CalibrationReport.fileName), encoder: encoder)
    }
}
