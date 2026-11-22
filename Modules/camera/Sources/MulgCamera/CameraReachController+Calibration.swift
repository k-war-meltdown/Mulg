import Foundation
import MulgContracts
import MulgEngine

/// Calibration: the player zooms out, in, out and in, pressing the hotkey after each. Mulg keeps
/// the values that followed exactly, finds the limits beside them, raises them and asks the player
/// to zoom out once more to confirm the camera now goes farther.
extension CameraReachController {
    /// Seconds Mulg waits for each press before giving up.
    private static let stepTimeout: Double = 180
    /// Seconds the player has to zoom out while a raised limit is being checked.
    private static let checkTimeout: Double = 20

    private enum Trial {
        case pairs(CameraCalibrationPlan.Group, [CameraMemory.Pair])
        case hold(CameraCalibrationPlan.Group)
    }

    /// The calibration hotkey or menu command: starts calibration or confirms the current step.
    func calibrationKeyPressed() {
        if automaticCalibration, calibrationState != .idle {
            // One press shows where it is; two quick presses cancel. A single press used to cancel,
            // which is what players did when they could not see that calibration was running.
            let now = ContinuousClock.now
            defer { lastCalibrationPress = now }
            if let last = lastCalibrationPress, now - last < .milliseconds(1500) {
                cancelCalibration(notice: Notice("Camera reach calibration cancelled"))
            } else {
                context.notices.showImportant(Notice("Camera reach is working (\(progressStep)/\(Self.progressSteps))",
                    lines: ["Keep still. Press \(hotkeyText) twice quickly to cancel."], duration: .seconds(4)))
            }
            return
        }
        switch calibrationState {
        case .idle:
            startCalibration()
        case .waiting(let step):
            capture(step)
        case .working:
            context.notices.showImportant(Notice("Camera reach is searching…", lines: ["One moment."], duration: .seconds(2)))
        case .checking:
            context.notices.showImportant(Notice("Camera reach is checking", lines: ["Zoom all the way out."], duration: .seconds(3)))
        }
    }

    func forgetCalibration() {
        cancelCalibration(notice: nil)
        restoreGameLimits()
        calibration = nil
        try? FileManager.default.removeItem(at: calibrationFile)
        if settings.extendedReach {
            setReport(.notCalibrated, "Calibration forgotten. Press \(hotkeyText) to calibrate again.")
        }
        context.notices.showImportant(Notice("Camera reach calibration forgotten", lines: ["The game's own zoom limit is back."]))
    }

    func startCalibration() {
        guard settings.extendedReach else {
            context.notices.showImportant(Notice("Camera reach is off", lines: [
                "Turn it on in Mulg: the game's settings → Controls → Camera reach."
            ], style: .warning, duration: .seconds(6)))
            return
        }
        // The game's own limits must be in place, or calibration would find the raised ones.
        restoreGameLimits()
        calibrationGeneration += 1
        setReport(.calibrating, "Calibrating…")
        // Mulg zooms the camera itself when the controls module can pinch; otherwise the player does.
        automaticCalibration = canZoom
        calibrationReport = CalibrationReport(gameVersion: Self.gameVersion, automatic: automaticCalibration)
        guard automaticCalibration else { prompt(.farthest, first: true); return }
        context.notices.showImportant(Notice("Camera reach is calibrating", lines: [
            "Stand still in an open area and don't touch the mouse or keys: Mulg zooms the camera in and out by itself (about a minute).",
            "Press \(hotkeyText) twice quickly to cancel."
        ], duration: .seconds(12)))
        autoStep(.farthest)
    }

    private func prompt(_ step: CameraCalibrationPlan.Step, first: Bool = false) {
        calibrationState = .waiting(step)
        var lines = ["\(step.instruction), then press \(hotkeyText)."]
        if first {
            lines.insert("Stand still in an open area (no walls behind the camera).", at: 0)
            lines.append("After the first press Mulg reads the game's memory for about 10 seconds: stay zoomed out until step 2 appears.")
        }
        context.notices.showImportant(Notice("Camera reach \(step.rawValue)/\(CameraCalibrationPlan.Step.allCases.count)",
                                    lines: lines, duration: .seconds(first ? 15 : 10)))
        let generation = calibrationGeneration
        calibrationTask?.cancel()
        calibrationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.stepTimeout))
            guard !Task.isCancelled, let self, generation == self.calibrationGeneration,
                  self.calibrationState == .waiting(step) else { return }
            self.cancelCalibration(notice: Notice("Camera reach calibration stopped",
                                                  lines: ["No key press for three minutes."], style: .warning))
        }
    }

    func cancelCalibration(notice: Notice?) {
        zoomTask?.cancel()
        zoomTask = nil
        context.events.publish(CameraZoomCancelled())
        guard calibrationState != .idle else { return }
        if calibrationReport?.result == "running" {
            calibrationReport?.result = notice?.title ?? "stopped"
            writeCalibrationReport()
        }
        automaticCalibration = false
        calibrationGeneration += 1
        calibrationTask?.cancel()
        calibrationTask = nil
        revertTrial()
        let finished = scan
        scan = nil
        // Freed on the memory queue, after any step still running there.
        CameraMemory.queue.async { _ = finished }
        calibrationState = .idle
        if let notice { context.notices.showImportant(notice) }
        if settings.extendedReach {
            if calibration != nil {
                scheduleSearch(restart: true)
            } else {
                setReport(.notCalibrated, "Not calibrated for this game. Press \(hotkeyText) in the game to calibrate.")
            }
        }
    }

    private func fail(_ lines: [String]) {
        if calibrationReport?.result == "running" {
            calibrationReport?.result = lines.joined(separator: " ")
            writeCalibrationReport() // cancelCalibration only writes reports still "running".
        }
        cancelCalibration(notice: Notice("Camera reach calibration failed",
                                         lines: lines + ["Press \(hotkeyText) to try again (in the open world, no menu open)."],
                                         style: .warning, duration: .seconds(8)))
    }

    // MARK: Steps

    private func capture(_ step: CameraCalibrationPlan.Step) {
        calibrationState = .working(step)
        calibrationTask?.cancel()
        let generation = calibrationGeneration
        let current = scan
        let logger = logger
        if step == .farthest, !automaticCalibration {
            context.notices.showImportant(Notice("Camera reach: reading the game's memory…",
                                        lines: ["Stay zoomed out until step 2 appears (about 10 seconds)."], duration: .seconds(10)))
        }
        CameraMemory.queue.async { [weak self] in
            var created: CameraScan?
            var failure: CameraScan.Failure?
            var remaining: UInt64 = 0
            var survivors: [CameraMemory.Survivor] = []
            switch step {
            case .farthest:
                do throws(CameraScan.Failure) {
                    let widest = try CameraScan.widest()
                    created = widest.scan
                    remaining = widest.scan.count
                    if widest.range != CameraMemory.searchRange {
                        logger.notice("Camera reach step 1: narrowed to \(widest.range.lowerBound, privacy: .public)…\(widest.range.upperBound, privacy: .public)")
                    }
                } catch {
                    failure = error
                    logger.error("Camera reach step 1 failed: \(error == .tooMany ? "too many values" : "no memory", privacy: .public)")
                }
            case .nearest: remaining = current?.keepDecreased() ?? 0
            case .farthestAgain: remaining = current?.keepFarthestAgain() ?? 0
            case .nearestAgain:
                remaining = current?.keepNearestAgain() ?? 0
                survivors = current?.survivors() ?? []
            }
            let result = (created, failure, remaining, survivors)
            Task { @MainActor [weak self] in
                self?.captured(step, generation: generation, scan: result.0, failure: result.1,
                               remaining: result.2, survivors: result.3)
            }
        }
    }

    private func captured(_ step: CameraCalibrationPlan.Step, generation: Int, scan created: CameraScan?,
                          failure: CameraScan.Failure?, remaining: UInt64, survivors: [CameraMemory.Survivor]) {
        guard generation == calibrationGeneration, calibrationState == .working(step) else {
            CameraMemory.queue.async { _ = created }
            return
        }
        if let created { scan = created }
        logger.notice("Camera reach step \(step.rawValue, privacy: .public): \(remaining, privacy: .public) value(s)")
        calibrationReport?.steps.append(remaining)
        writeCalibrationReport()
        if let failure {
            fail(failure == .tooMany
                 ? ["The game has too much data in memory to search. Try again in a quieter place (fewer characters on screen)."]
                 : ["Mulg could not reserve memory for the search."])
            return
        }
        guard remaining > 0 else {
            fail(step == .farthest ? ["Nothing to search was found in the game's memory."]
                 : ["No value followed the zoom. Zoom all the way, wait until the camera stops, and keep the character still."])
            return
        }
        if let next = step.next {
            if automaticCalibration { autoStep(next) } else { prompt(next) }
            return
        }
        let finished = scan
        scan = nil
        CameraMemory.queue.async { _ = finished }
        findLimits(CameraCalibrationPlan.groups(survivors), generation: generation)
    }

    // MARK: Finding and checking the limits

    /// Groups whose limits sit side by side in memory are tried first (raising one is saved and
    /// re-applied every launch); then holding a value past the limit every few milliseconds.
    private func findLimits(_ groups: [CameraCalibrationPlan.Group], generation: Int) {
        guard !groups.isEmpty else {
            calibrationReport?.result = "no camera distance among the values that followed the zoom"
            fail(["No camera distance was found. The game may not let the camera zoom, or the character moved."])
            return
        }
        context.notices.showImportant(Notice("Camera reach \(Self.progressSteps)/\(Self.progressSteps): finding the zoom limit…",
                                             lines: ["Keep still: Mulg then tests it by zooming out."], duration: .seconds(8)))
        let excluded = groups.flatMap(\.addresses)
        CameraMemory.queue.async { [weak self] in
            let pairs = CameraMemory.pairs(for: groups, excluding: excluded)
            let regions = groups.map { $0.addresses.prefix(4).map { address -> String in
                guard let region = CameraMemory.region(of: address) else { return "unknown" }
                return "tag \(region.tag), \(region.size >> 10) KB"
            } }
            Task { @MainActor [weak self] in
                guard let self, generation == self.calibrationGeneration else { return }
                self.calibrationReport?.groups = groups.indices.map { index in
                    CalibrationReport.Group(farthest: Double(groups[index].farthest), nearest: Double(groups[index].nearest),
                                            copies: groups[index].addresses.count, regions: regions[index],
                                            pairs: pairs[index]?.count)
                }
                var trials: [Trial] = []
                for (group, found) in zip(groups, pairs) where found.map({ !$0.isEmpty }) == true {
                    trials.append(.pairs(group, found!))
                }
                trials = Array(trials.prefix(4))
                // Values the game keeps recomputing can still be held past the limit while playing.
                trials += groups.prefix(4).map { .hold($0) }
                self.calibrationState = .checking
                self.run(trials, groups: groups, index: 0, generation: generation)
            }
        }
    }

    private func run(_ trials: [Trial], groups: [CameraCalibrationPlan.Group], index: Int, generation: Int) {
        guard generation == calibrationGeneration else { return }
        guard index < trials.count else {
            calibrationState = .idle
            automaticCalibration = false
            calibrationTask = nil
            calibrationReport?.result = "unsupported"
            writeCalibrationReport()
            clearCrashMarkerIfUnchanged()
            setReport(.unsupported, "Calibration found \(groups.count) camera value(s), but raising or holding none of them moved the camera. Send the camera-calibration.json report to look into it.")
            context.notices.showImportant(Notice("Camera reach can't raise this game's limit yet", lines: [
                "The camera values were found, but none of them moved the camera farther.",
                "Details: Mulg's diagnostics folder, camera-calibration.json."
            ], style: .warning, duration: .seconds(10)))
            return
        }
        let next = { [weak self] in self?.run(trials, groups: groups, index: index + 1, generation: generation) }
        switch trials[index] {
        case let .pairs(group, pairs):
            let raised = raisedBits(group.farthestBits)
            trialLimits = (group.farthestBits ^ CameraCalibration.mask, raised)
            CameraCrashGuard.markActive(context)
            trialWrites = pairs.map(\.address).filter {
                CameraMemory.swap($0, expected: group.farthestBits, replacement: raised) == .swapped
            }
            guard !trialWrites.isEmpty else { next(); return }
            zoomForCheck(firstTry: index == 0)
            watch(groups, generation: generation) { [weak self] seen in
                guard let self else { return }
                let passed = seen != nil
                self.calibrationReport?.trials.append(.init(kind: "pairs", farthest: Double(group.farthest),
                                                            writes: self.trialWrites.count, passed: passed,
                                                            seen: seen.map(Double.init)))
                if passed {
                    self.acceptPairs(group, pairs: pairs.filter { self.trialWrites.contains($0.address) }, raised: raised)
                } else {
                    self.revertTrial()
                    next()
                }
            }
        case let .hold(group):
            holdTrial(group, groups: groups, generation: generation) { [weak self] statistics, passed in
                guard let self else { return }
                self.calibrationReport?.trials.append(.init(kind: "hold", farthest: Double(group.farthest),
                                                            writes: group.addresses.count, passed: passed,
                                                            seen: nil, statistics: statistics))
                if passed { self.acceptHold(group, groups: groups) } else { next() }
            }
        }
    }

    /// Zooms out past the old limit (automatic calibration) or asks the player to.
    private func zoomForCheck(firstTry: Bool) {
        if automaticCalibration {
            context.notices.showImportant(Notice("Camera reach: checking", lines: ["Zooming out past the old limit…"], duration: .seconds(4)))
            zoomTask?.cancel()
            zoomTask = Task { @MainActor [weak self] in
                if !firstTry { await self?.requestZoom(outward: false, gestures: 1) }
                await self?.requestZoom(outward: true)
            }
        } else {
            context.notices.showImportant(Notice(firstTry ? "Camera reach: almost done" : "Camera reach: one more try",
                                        lines: [firstTry ? "Now zoom all the way OUT: the camera should go farther than before."
                                                : "Zoom in a little, then all the way OUT again."],
                                        duration: .seconds(10)))
        }
    }

    /// Waits up to `checkTimeout` for any value that followed the zoom to pass its own limit;
    /// returns the value seen, or nil.
    private func watch(_ groups: [CameraCalibrationPlan.Group], generation: Int,
                       completion: @escaping @MainActor (Float?) -> Void) {
        let watched = groups.flatMap { group in group.addresses.map { ($0, group.farthest) } }
        calibrationTask?.cancel()
        calibrationTask = Task { @MainActor [weak self] in
            let deadline = ContinuousClock.now + .seconds(Self.checkTimeout)
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self, generation == self.calibrationGeneration else { return }
                for (address, farthest) in watched {
                    if let value = CameraMemory.readFloat(address), CameraCalibrationPlan.passedLimit(value, farthest: farthest) {
                        completion(value)
                        return
                    }
                }
            }
            guard !Task.isCancelled, let self, generation == self.calibrationGeneration else { return }
            completion(nil)
        }
    }

    /// Holds `group` past its limit for two and a half seconds once the camera is zoomed out, and
    /// judges by what the game did: another camera value passing its limit proves the camera
    /// moved; without one, the held value must still be past the limit and eased by the game.
    private func holdTrial(_ group: CameraCalibrationPlan.Group, groups: [CameraCalibrationPlan.Group], generation: Int,
                           completion: @escaping @MainActor (CameraHold.Statistics, Bool) -> Void) {
        let target = holdTarget(group, groups: groups)
        let engine = CameraHold()
        holdEngine?.stop()
        holdEngine = engine
        calibrationTask?.cancel()
        calibrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if self.automaticCalibration {
                await self.requestZoom(outward: true)
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else {
                    if self.holdEngine === engine { self.holdEngine = nil }
                    return
                }
                CameraCrashGuard.markActive(self.context)
                engine.start(target, force: true)
            } else {
                self.context.notices.showImportant(Notice("Camera reach: last checks", lines: ["Zoom all the way OUT and keep it there."],
                                                 duration: .seconds(8)))
                CameraCrashGuard.markActive(self.context)
                engine.start(target)
                let deadline = ContinuousClock.now + .seconds(Self.checkTimeout)
                while engine.statistics.ticks == 0, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(100))
                    if Task.isCancelled {
                        engine.stop()
                        if self.holdEngine === engine { self.holdEngine = nil }
                        Self.restore(target)
                        self.clearCrashMarkerIfUnchanged()
                        return
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(2500))
            let statistics = engine.stop()
            if self.holdEngine === engine { self.holdEngine = nil }
            Self.restore(target)
            self.clearCrashMarkerIfUnchanged()
            guard !Task.isCancelled, generation == self.calibrationGeneration else { return }
            completion(statistics, CameraCalibrationPlan.holdWorked(statistics, watched: !target.watched.isEmpty))
        }
    }

    /// What to hold for `group`: its addresses at the raised value, watched by every other value.
    /// A normalised zoom level (0 to 1) is extended so that the distance, from another group,
    /// reaches the raised distance.
    private func holdTarget(_ group: CameraCalibrationPlan.Group, groups: [CameraCalibrationPlan.Group]) -> CameraHold.Target {
        let distance = groups.first { $0.nearest >= CameraCalibrationPlan.levelZero && $0 != group }
        let raised = CameraCalibrationPlan.heldBits(group, distance: distance, reach: settings.reach)
        let watched = groups.filter { $0 != group }.flatMap { other in other.addresses.map { ($0, other.farthestBits) } }
        return CameraHold.Target(addresses: group.addresses, farthestBits: group.farthestBits, raisedBits: raised,
                                 watched: Array(watched.prefix(32)))
    }

    /// Puts held values back at the game's limit (the game also recomputes them by itself).
    private static func restore(_ target: CameraHold.Target) {
        for address in target.addresses {
            _ = CameraMemory.swap(address, expected: target.raisedBits, replacement: target.farthestBits)
        }
    }

    /// Undoes the writes of a trial that did not work (or a calibration cancelled mid-check).
    func revertTrial() {
        defer { trialWrites = []; trialLimits = nil }
        guard let limits = trialLimits else { return }
        let farthest = limits.farthestMasked ^ CameraCalibration.mask
        for address in trialWrites { _ = CameraMemory.swap(address, expected: limits.raised, replacement: farthest) }
        trialWrites = []
        clearCrashMarkerIfUnchanged()
    }

    // MARK: Results

    private func acceptPairs(_ group: CameraCalibrationPlan.Group, pairs: [CameraMemory.Pair], raised: UInt32) {
        let addresses = trialWrites
        trialWrites = []
        trialLimits = nil
        calibrationTask = nil
        calibrationState = .idle
        automaticCalibration = false
        calibrationReport?.result = "raised \(addresses.count) limit pair(s)"
        writeCalibrationReport()
        let saved = CameraCalibration(farthestBits: group.farthestBits, nearestBits: group.nearestBits,
                                      offsets: CameraCalibrationPlan.offsets(pairs), pairs: addresses.count,
                                      gameVersion: Self.gameVersion)
        save(saved)
        applied = .pairs(RaisedPairs(addresses: addresses, farthestMasked: group.farthestBits ^ CameraCalibration.mask,
                                     raisedBits: raised))
        appliedReport()
        startKeeper()
        logger.notice("Camera reach calibrated: \(addresses.count, privacy: .public) limit(s)")
        zoomToReach()
        context.notices.showImportant(Notice("Camera reach works", lines: [
            "Mulg zoomed the camera out to your Camera reach distance (\(Int(((settings.reach - 1) * 100).rounded())) % farther than the game allows).",
            "Saved: it is applied automatically from now on."
        ], duration: .seconds(6)))
    }

    private func acceptHold(_ group: CameraCalibrationPlan.Group, groups: [CameraCalibrationPlan.Group]) {
        trialWrites = []
        trialLimits = nil
        calibrationTask = nil
        calibrationState = .idle
        automaticCalibration = false
        calibrationReport?.result = "holding \(group.addresses.count) value(s) past the limit"
        writeCalibrationReport()
        // A saved calibration that did not help this session would only waste searches later.
        calibration = nil
        try? FileManager.default.removeItem(at: calibrationFile)
        let target = holdTarget(group, groups: groups)
        let engine = CameraHold()
        holdEngine = engine
        engine.start(target)
        applied = .hold(Hold(addresses: target.addresses, farthestMasked: group.farthestBits ^ CameraCalibration.mask,
                             raisedBits: target.raisedBits))
        appliedReport()
        logger.notice("Camera reach holding \(group.addresses.count, privacy: .public) value(s)")
        zoomToReach()
        context.notices.showImportant(Notice("Camera reach works", lines: [
            "Mulg zoomed the camera out to your Camera reach distance. Scroll in to come closer; scroll all the way out to go back.",
            "This game recomputes its camera every frame, so this lasts for this session: press \(hotkeyText) again next time."
        ], duration: .seconds(8)))
    }

    static var gameVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

// MARK: Zooming for the player

extension CameraReachController {
    /// Whole pinches that reach the game's zoom limit from anywhere.
    static let fullZoomGestures = 6

    /// The controls module performs zoom sweeps (`CameraZoomRequested`); without it the player zooms.
    var canZoom: Bool { context.events.subscriberCount(for: CameraZoomRequested.self) > 0 }

    /// Zooms the camera all the way (or `gestures` pinches) and returns when the pinches are done.
    func requestZoom(outward: Bool, gestures: Int = fullZoomGestures) async {
        guard !Task.isCancelled, settings.extendedReach else { return }
        context.events.publish(CameraZoomRequested(outward: outward, gestures: gestures))
        try? await Task.sleep(for: CameraZoomRequested.duration(gestures: gestures))
    }

    /// One calibration step without the player: zoom, let the camera settle, then capture.
    func autoStep(_ step: CameraCalibrationPlan.Step) {
        calibrationState = .waiting(step)
        context.notices.showImportant(Notice("Camera reach \(step.rawValue)/\(Self.progressSteps)",
            lines: [step == .farthest ? "Zooming out, then reading the game's memory (about 10 seconds). Keep still."
                    : "Zooming \(step.zoomsOut ? "out" : "in") and comparing. Keep still."], duration: .seconds(8)))
        let generation = calibrationGeneration
        calibrationTask?.cancel()
        calibrationTask = Task { @MainActor [weak self] in
            await self?.requestZoom(outward: step.zoomsOut)
            // The camera eases to its new distance; the value must have stopped moving.
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self, generation == self.calibrationGeneration,
                  self.calibrationState == .waiting(step) else { return }
            self.capture(step)
        }
    }
}

extension CameraReachController {
    /// After a calibration that worked: zoom all the way out, so the camera goes straight to the
    /// Camera reach distance (in hold mode the extension starts when the game reaches its limit).
    func zoomToReach() {
        guard canZoom else { return }
        zoomTask?.cancel()
        zoomTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.requestZoom(outward: true)
        }
    }
}

extension CameraReachController {
    /// Four zoom steps, then finding and testing the limit.
    static let progressSteps = CameraCalibrationPlan.Step.allCases.count + 1

    /// The step shown to the player while calibrating.
    var progressStep: Int {
        switch calibrationState {
        case .waiting(let step), .working(let step): step.rawValue
        case .checking: Self.progressSteps
        case .idle: 0
        }
    }
}
