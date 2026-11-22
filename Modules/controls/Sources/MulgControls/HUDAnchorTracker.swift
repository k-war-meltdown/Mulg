#if canImport(UIKit) && !os(watchOS)
import CoreGraphics
import Foundation
import MulgBridge
import MulgContracts
import MulgControlLayout
import MulgEngine

private struct HUDGroupCandidate: Sendable {
    let group: HUDLayoutGroup
    let points: [HUDLayoutPoint]
    let confidence: Double
    let regime: String
    let anchors: [ControlHUDAnchor]
    let reflow: Bool
}

/// Automatic visual correction above the existing canvas/layout module. Native hitboxes and
/// stable HUD shapes bootstrap references; uncertainty keeps the original map without setup.
@MainActor
final class HUDAnchorTracker {
    struct Snapshot: Equatable, Sendable {
        let revision: UInt64
        let rect: CGRect
        let aspect: Double
        let pointAspect: Double
    }
    private let bridge: any MacBridge
    private let snapshot: () -> Snapshot?
    private let canTrack: () -> Bool
    private let activeLayer: () -> Int
    private let notice: (String, String, Bool) -> Void
    private let beginCapture: () -> UUID
    private let endCapture: (UUID) -> Void
    private var map: KeymappingData?
    private var manualReferences: [ControlHUDAnchor] = []
    private var actions: [ControlBindingAddress: any MulgAction] = [:]
    private var task: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var epoch: UInt64 = 0
    private var states: [UUID: String] = [:]
    private var confidence: [UUID: Double] = [:]
    private var enabled = true
    private var captureError: String?
    private var automatic = true
    private var permissionRequested = false
    private var captureBackoffUntil: ContinuousClock.Instant?
    /// What the user can see of the tracker's work, compared between automatic rechecks.
    private struct Outcome: Equatable {
        let states: [ControlBindingAddress: String]
        let references: Set<ControlBindingAddress>
        let verified: Set<ControlBindingAddress>
        let applied: Set<String>
    }
    private var outcome: Outcome {
        // Reverified patches get new UUIDs even when the visible HUD is unchanged.
        // Compare the binding/status so stable captures can reach the quiet backoff.
        let stableStates = Dictionary(uniqueKeysWithValues: references.map {
            ($0.address, states[$0.id] ?? "Waiting for a visible HUD")
        })
        return Outcome(states: stableStates, references: Set(automaticReferences.keys),
                       verified: nativeVerifiedAddresses, applied: appliedGroups)
    }
    private var lastOutcome: Outcome?
    /// Automatic rechecks in a row that changed nothing; each may capture the window.
    private var quietRechecks = 0
    private var automaticReferences: [ControlBindingAddress: ControlHUDAnchor] = [:]
    private var referencesDirty = false
    private var referenceMisses: [UUID: Int] = [:]
    private var nativeVerifiedAddresses: Set<ControlBindingAddress> = []
    private var referenceStore: HUDReferenceStore?
    private var cacheStatus = "No automatic references yet"
    private var scanCursor = 0
    private let nativeHUD = NativeHUDAnchoring()
    private struct PendingPosition {
        let point: CGPoint?
        let snapshot: Snapshot?
        let anchorID: UUID?
        let deadline: ContinuousClock.Instant
    }
    private var pendingPositions: [ControlBindingAddress: PendingPosition] = [:]
    private var layoutSolver: ControlLayoutSolver?
    private var groupEvidence: [ControlBindingAddress: HUDLayoutPoint] = [:]
    private var groupConfidence: [ControlBindingAddress: Double] = [:]
    private var appliedGroups: Set<String> = []
    private struct PendingLayout {
        let group: HUDLayoutGroup
        let points: [HUDLayoutPoint]?
        let sample: Snapshot?
        let deadline: ContinuousClock.Instant
    }
    private var pendingLayouts: [String: PendingLayout] = [:]
    private var lastLayoutGeometry: ViewportLayoutGeometry?

    init(bridge: any MacBridge, snapshot: @escaping () -> Snapshot?, canTrack: @escaping () -> Bool,
         activeLayer: @escaping () -> Int,
         beginCapture: @escaping () -> UUID, endCapture: @escaping (UUID) -> Void,
         notice: @escaping (String, String, Bool) -> Void) {
        self.bridge = bridge; self.snapshot = snapshot; self.canTrack = canTrack; self.notice = notice
        self.activeLayer = activeLayer
        self.beginCapture = beginCapture; self.endCapture = endCapture
    }

    var report: [String: Any] {
        ["enabled": enabled, "automatic": automatic, "confirmed": manualReferences.count,
         "automaticReferences": automaticReferences.count, "nativeControls": nativeVerifiedAddresses.count,
         "cacheStatus": cacheStatus,
         "layoutGroups": layoutSolver?.groups.count ?? 0,
         "measuredLayouts": layoutSolver?.samples.count ?? 0,
         "verifiedLayoutGroups": layoutSolver?.verifiedGroupCount ?? 0,
         "appliedGroups": appliedGroups.count, "pendingGroups": pendingLayouts.count,
         "layoutSystem": "Viewport canvas + measured HUD group constraints",
         "captureStatus": captureError ?? (automatic ? "Native hitboxes / permission-gated game capture" : "Manual overrides only"),
         "anchors": references.map { anchor in
            ["layer": anchor.address.layer, "kind": anchor.address.kind.rawValue, "index": anchor.address.index,
             "status": states[anchor.id] ?? "Waiting for a visible HUD", "confidence": confidence[anchor.id] ?? 0] as [String: Any]
         }]
    }

    private var references: [ControlHUDAnchor] {
        let manual = manualReferences
        let addresses = Set(manual.map(\.address))
        return manual + (automatic ? automaticReferences.values.filter { !addresses.contains($0.address) } : [])
    }

    func configure(map: KeymappingData, actions: [ControlBindingAddress: any MulgAction], referenceStore: HUDReferenceStore?) {
        cancel(); pendingPositions.removeAll(); self.map = map; self.actions = actions
        manualReferences = map.validHUDAnchors
        self.referenceStore = referenceStore
        states.removeAll(); confidence.removeAll(); referenceMisses.removeAll()
        nativeVerifiedAddresses.removeAll(); referencesDirty = false; scanCursor = 0; nativeHUD.reset()
        automaticReferences = Dictionary(uniqueKeysWithValues: (referenceStore?.read(for: map) ?? []).map { ($0.address, $0) })
        layoutSolver = ControlLayoutSolver(map: map, cached: referenceStore?.readLayouts(for: map) ?? [])
        pendingLayouts.removeAll(); appliedGroups.removeAll(); groupEvidence.removeAll(); groupConfidence.removeAll()
        lastLayoutGeometry = nil
        cacheStatus = automaticReferences.isEmpty ? "Learning automatically" : "Cached references require live verification"
        startMonitoring()
        recheck()
    }

    func updateAutomatic(_ automatic: Bool) {
        guard self.automatic != automatic else { return }
        self.automatic = automatic
        suspend(); startMonitoring(); recheck()
    }

    /// Called only by the existing stable, atomic viewport transaction. Window resize,
    /// fullscreen, selected-layer changes and fixed-pixel settings all reach this path.
    func viewportCommitted(_ geometry: ViewportLayoutGeometry) {
        guard geometry.isValid, lastLayoutGeometry != geometry else { return }
        lastLayoutGeometry = geometry
        guard enabled, automatic, canTrack(), let current = snapshot(), current.revision == geometry.revision else { return }
        let effective = map.map { Set(ControlBindingGraph($0).effectiveBindings(activeLayer: activeLayer()).map(\.address)) } ?? []
        for group in activeGroups where Set(group.members).isSubset(of: effective) {
            if let prediction = layoutSolver?.prediction(for: group, aspect: current.aspect,
                revision: current.revision, pointAspect: current.pointAspect) {
                publish(group: group, points: prediction.points, sample: current)
            }
        }
    }

    /// Seconds between automatic rechecks: 5 while the HUD is being learned or changes, doubling
    /// up to 60 while rechecks change nothing (each may capture the whole window).
    static func monitorInterval(quietRechecks: Int) -> Duration {
        .seconds(min(60, 5 << min(quietRechecks, 4)))
    }

    /// One low-frequency task; matching/capture never runs in the input/frame callback.
    private func startMonitoring() {
        monitorTask?.cancel(); monitorTask = nil
        quietRechecks = 0; lastOutcome = nil
        guard automatic, !actions.isEmpty else { return }
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.monitorInterval(quietRechecks: self?.quietRechecks ?? 0))
                guard !Task.isCancelled, let self else { return }
                if self.enabled, self.task == nil, self.canTrack() {
                    let current = self.outcome
                    self.quietRechecks = current == self.lastOutcome ? min(4, self.quietRechecks + 1) : 0
                    self.lastOutcome = current
                    self.recheck()
                }
            }
        }
    }

    func resetAutomaticReferences() -> Bool {
        guard referenceStore?.remove() ?? true else { return false }
        automaticReferences.removeAll(); referenceMisses.removeAll(); referencesDirty = false; nativeHUD.reset()
        if let map { layoutSolver = ControlLayoutSolver(map: map) }
        suspend(); cacheStatus = "Learning automatically"; recheck()
        return true
    }

    /// Memory pressure: no window captures (a full-window screenshot each) for a minute.
    /// Positions already found stay applied.
    func pauseCaptures() {
        captureBackoffUntil = .now + .seconds(60)
    }

    func cancel() {
        epoch &+= 1; task?.cancel(); task = nil
        pendingPositions = pendingPositions.filter { $0.value.point == nil }
        pendingLayouts = pendingLayouts.filter { $0.value.points == nil }
        groupEvidence.removeAll(); groupConfidence.removeAll()
        // The owner keeps editor input paused until this confirmation task completes/cancels.
    }

    func suspend() {
        cancel(); nativeVerifiedAddresses.removeAll(); clearPositions()
        // A changed context is checked at the 5-second pace again, not after a long quiet wait.
        if quietRechecks > 0 { startMonitoring() }
        layoutSolver?.invalidateVerification()
    }

    /// Resize is a geometry transaction, not a game/menu context change. Keep verified
    /// measurements available for prediction while discarding in-flight captures/contacts.
    func suspendForViewportChange() {
        cancel(); nativeVerifiedAddresses.removeAll(); clearPositions()
        // A changed context is checked at the 5-second pace again, not after a long quiet wait.
        if quietRechecks > 0 { startMonitoring() }
    }

    private func clearPositions(excluding preserved: Set<ControlBindingAddress> = []) {
        guard !actions.isEmpty else { return }
        let aspect = snapshot()?.aspect ?? 0
        var grouped: Set<ControlBindingAddress> = []
        // Include previously applied groups when automatic mode is being disabled.
        // Otherwise an unavailable member could outlive that setting.
        let restorable = (layoutSolver?.groups ?? []).filter { group in
            group.members.allSatisfy { actions[$0] != nil }
                && (appliedGroups.contains(group.id) || pendingLayouts[group.id] != nil
                    || activeGroups.contains { $0.id == group.id })
        }
        for group in restorable where !group.members.contains(where: preserved.contains) {
            grouped.formUnion(group.members)
            publish(group: group, points: nil, sample: nil)
        }
        for address in actions.keys where !preserved.contains(address) && !grouped.contains(address) {
            restoreMapPosition(address, aspect: aspect)
        }
    }

    private var activeGroups: [HUDLayoutGroup] {
        guard automatic else { return [] }
        let manual = Set(manualReferences.map(\.address))
        return (layoutSolver?.groups ?? []).filter { group in
            !group.members.contains(where: manual.contains) && group.members.allSatisfy { actions[$0] != nil }
        }
    }

    private func restoreMapPosition(_ address: ControlBindingAddress, aspect: Double) {
        // Individual misses cannot tear down one member of a coherent verified group.
        if let group = activeGroups.first(where: { $0.members.contains(address) }),
           appliedGroups.contains(group.id) || pendingLayouts[group.id]?.points != nil { return }
        guard let action = actions[address] else { return }
        if action.applyHUDPosition(nil, aspect: aspect) { pendingPositions[address] = nil }
        else { pendingPositions[address] = PendingPosition(point: nil, snapshot: nil, anchorID: nil, deadline: .now + .seconds(30)) }
    }

    private func persistReferences(for map: KeymappingData) {
        guard referencesDirty else { return }
        guard let referenceStore else { cacheStatus = "Session references active; cache unavailable"; return }
        let generation = epoch
        referenceStore.writeInBackground(Array(automaticReferences.values), for: map, layouts: layoutSolver?.samples) { [weak self] saved in
            Task { @MainActor [weak self] in
                guard let self, self.epoch == generation else { return }
                if saved { self.referencesDirty = false; self.cacheStatus = "Automatic references saved" }
                else { self.cacheStatus = "Session references active; cache unavailable" }
            }
        }
    }

    /// Bounded retry on the existing frame callback, with no capture or image matching here.
    func applyPending() {
        guard !pendingPositions.isEmpty || !pendingLayouts.isEmpty else { return }
        let current = snapshot()
        for (id, pending) in pendingLayouts {
            if pending.points != nil && (pending.sample != current || .now > pending.deadline || !enabled || !canTrack()) {
                pendingLayouts[id] = nil; continue
            }
            if commit(group: pending.group, points: pending.points, sample: pending.sample) { pendingLayouts[id] = nil }
        }
        for (address, pending) in pendingPositions {
            if pending.point != nil && (pending.snapshot != current || .now > pending.deadline || !enabled || !canTrack()) {
                pendingPositions[address] = nil; continue
            }
            if actions[address]?.applyHUDPosition(pending.point, aspect: current?.aspect ?? 0) == true {
                pendingPositions[address] = nil
                if let id = pending.anchorID { states[id] = "Verified" }
            }
        }
    }

    private func commit(group: HUDLayoutGroup, points: [HUDLayoutPoint]?, sample: Snapshot?) -> Bool {
        guard group.members.allSatisfy({ actions[$0]?.canApplyHUDPosition == true }) else { return false }
        if let sample { guard snapshot() == sample, enabled, canTrack() else { return false } }
        if let points { guard Set(points.map(\.address)) == Set(group.members) else { return false } }
        let aspect = sample?.aspect ?? snapshot()?.aspect ?? 0
        // Main actor, no suspension after preflight: every member adopts the same revision.
        for address in group.members {
            let value = points?.first { $0.address == address }
            _ = actions[address]?.applyHUDLayout(value?.point, size: value?.size.map { CGFloat($0) },
                available: value?.available ?? true, aspect: aspect)
            pendingPositions[address] = nil
        }
        if points == nil { appliedGroups.remove(group.id) } else { appliedGroups.insert(group.id) }
        return true
    }

    private func publish(group: HUDLayoutGroup, points: [HUDLayoutPoint]?, sample: Snapshot?) {
        if commit(group: group, points: points, sample: sample) { pendingLayouts[group.id] = nil }
        else {
            // Keep accepting input at the existing layout. The main-actor preflight
            // will adopt the complete group when all contacts are idle; never gate keys.
            pendingLayouts[group.id] = PendingLayout(group: group, points: points, sample: sample,
                deadline: .now + .seconds(points == nil ? 30 : 3))
        }
    }

    private func flushGroupEvidence(map: KeymappingData, sample: Snapshot) {
        for group in activeGroups {
            let points = group.members.compactMap { groupEvidence[$0] }
            guard points.count == group.members.count else { continue }
            let regime = HUDGroupSearch.regime(for: points, aspect: sample.aspect)
            let confidence = group.members.compactMap { groupConfidence[$0] }.min() ?? 0
            guard let resolution = layoutSolver?.observe(group: group, points: points, map: map,
                aspect: sample.aspect, pointAspect: sample.pointAspect, confidence: confidence, regime: regime,
                reflow: true, revision: sample.revision) else { continue }
            referencesDirty = true
            publish(group: group, points: resolution.points, sample: sample)
        }
    }

    func toggle() {
        enabled.toggle(); suspend()
        notice("HUD tracking \(enabled ? "enabled" : "paused")",
            enabled ? "Controls will be located and checked automatically." : "The original control layout is active. Saved references are kept.", false)
        if enabled { recheck() }
    }

    func recheck(showResult: Bool = false) {
        cancel()
        guard enabled, let map, !actions.isEmpty, automatic || !references.isEmpty else {
            if showResult { notice("HUD tracking inactive", "Automatic anchoring is available for mapped touchscreen buttons and joysticks.", false) }
            return
        }
        let generation = epoch
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self else { return }
            defer {
                if generation == self.epoch {
                    self.task = nil
                    self.persistReferences(for: map)
                }
            }
            guard !Task.isCancelled, generation == self.epoch, self.canTrack(), let start = self.snapshot() else { return }
            let layer = self.activeLayer()
            let effective = Set(ControlBindingGraph(map).effectiveBindings(activeLayer: layer).map(\.address))
            let baseTargets = effective.compactMap { map.hudTarget(at: $0, aspect: start.aspect) }.sorted {
                if $0.address.layer != $1.address.layer { return $0.address.layer < $1.address.layer }
                if $0.address.kind != $1.address.kind { return $0.address.kind.rawValue < $1.address.kind.rawValue }
                return $0.address.index < $1.address.index
            }
            let groups = self.activeGroups.filter { Set($0.members).isSubset(of: effective) }
            var seeds: [ControlBindingAddress: HUDLayoutPoint] = [:]
            for group in groups {
                if let prediction = self.layoutSolver?.prediction(for: group, aspect: start.aspect,
                    revision: start.revision, pointAspect: start.pointAspect, includeUnverified: true) {
                    for point in prediction.points where point.available { seeds[point.address] = point }
                    // Only evidence verified in this process can predict an applied layout.
                    if self.layoutSolver?.prediction(for: group, aspect: start.aspect, revision: start.revision,
                        pointAspect: start.pointAspect) != nil {
                        self.publish(group: group, points: prediction.points, sample: start)
                    }
                }
            }
            let targets = baseTargets.map { target -> HUDControlTarget in
                guard let seed = seeds[target.address] else { return target }
                var transform = target.transform
                transform.xCoord = CGFloat(seed.x); transform.yCoord = CGFloat(seed.y)
                if let size = seed.size { transform.size = CGFloat(size) }
                return HUDControlTarget(address: target.address, bindingSignature: target.bindingSignature, transform: transform)
            }
            guard !targets.isEmpty else { return }
            // Bound the work per capture; round-robin handles arbitrarily large imported maps.
            let begin = self.scanCursor % targets.count
            let batchLimit = min(16, max(8, groups.map { $0.members.count }.max() ?? 0))
            var collectedBatch: [HUDControlTarget] = []
            for offset in 0..<targets.count {
                let target = targets[(begin + offset) % targets.count]
                if collectedBatch.contains(where: { $0.address == target.address }) { continue }
                let unit = groups.first(where: { $0.members.contains(target.address) && $0.members.count <= batchLimit })
                    .map { group in targets.filter { group.members.contains($0.address) } } ?? [target]
                let additions = unit.filter { item in !collectedBatch.contains { $0.address == item.address } }
                guard collectedBatch.count + additions.count <= batchLimit else { continue }
                collectedBatch.append(contentsOf: additions)
                if collectedBatch.count == batchLimit { break }
            }
            let batch = collectedBatch
            self.scanCursor = (begin + batch.count) % targets.count
            let batchAddresses = Set(batch.map(\.address))
            let manualAddresses = Set(self.manualReferences.map(\.address))
            self.nativeVerifiedAddresses.subtract(batchAddresses)
            var anchors = self.references.filter { effective.contains($0.address) && batchAddresses.contains($0.address) }
            for anchor in self.references where !effective.contains(anchor.address) {
                self.states[anchor.id] = "Inactive binding or layer"
            }
            for anchor in anchors { self.states[anchor.id] = "Checking alignment" }
            var prior: [UUID: HUDAnchorMatch] = [:]
            struct Observation: Sendable {
                let candidate: HUDAutomaticCandidate
                var passes: Int
            }
            var observations: [ControlBindingAddress: Observation] = [:]
            var verified: Set<UUID> = []
            var nativePrior: [ControlBindingAddress: CGPoint] = [:]
            var nativeVerified: Set<ControlBindingAddress> = []
            var groupPrior: [String: (candidate: HUDGroupCandidate, passes: Int)] = [:]
            for attempt in 0..<4 {
                guard !Task.isCancelled, generation == self.epoch, self.canTrack(), self.activeLayer() == layer, self.snapshot() == start else { return }
                if self.automatic {
                    let positions = self.nativeHUD.positions(for: batch.filter { !manualAddresses.contains($0.address) })
                    var stable: Set<ControlBindingAddress> = []
                    for (address, point) in positions {
                        if let previous = nativePrior[address],
                           hypot(Double(previous.x - point.x) * start.pointAspect, Double(previous.y - point.y)) < 0.003 {
                            self.adopt(point, address: address, anchorID: nil, sample: start)
                            stable.insert(address)
                        }
                    }
                    for address in nativeVerified.subtracting(stable) {
                        self.groupEvidence[address] = nil; self.groupConfidence[address] = nil
                        self.restoreMapPosition(address, aspect: start.aspect)
                    }
                    nativePrior = positions
                    nativeVerified = stable
                    self.flushGroupEvidence(map: map, sample: start)
                }
                // Native-only interfaces can be checked twice without asking to record them.
                if attempt == 0, self.automatic,
                   batch.allSatisfy({ nativePrior[$0.address] != nil }) {
                    try? await Task.sleep(for: .milliseconds(300)); continue
                }
                let knownAddresses = Set(anchors.map(\.address))
                let discoveryTargets = self.automatic ? batch.filter {
                    !knownAddresses.contains($0.address) && !nativeVerified.contains($0.address)
                } : []
                let pending = anchors.filter { !verified.contains($0.id) && !nativeVerified.contains($0.address) }
                if pending.isEmpty && discoveryTargets.isEmpty { self.flushGroupEvidence(map: map, sample: start); break }
                if !showResult, let deadline = self.captureBackoffUntil, .now < deadline {
                    try? await Task.sleep(for: .milliseconds(300)); continue
                }
                let requestAccess = self.automatic && !self.permissionRequested
                if requestAccess { self.permissionRequested = true }
                let capture = await self.capture(start, requestPermission: requestAccess)
                guard !Task.isCancelled, generation == self.epoch, self.canTrack(), self.snapshot() == start else { return }
                guard let image = capture.image else {
                    self.captureError = capture.error
                    self.captureBackoffUntil = .now + .seconds(30)
                    for anchor in anchors { self.states[anchor.id] = "Capture unavailable; original mapping" }
                    self.nativeVerifiedAddresses = nativeVerified
                    self.clearPositions(excluding: nativeVerified)
                    if showResult { self.notice("HUD tracking unavailable", capture.error ?? "Allow game-window recording for automatic HUD detection.", true) }
                    return
                }
                self.captureError = nil
                self.captureBackoffUntil = nil
                let enrollment = observations
                let anchorAddresses = Set(anchors.map(\.address))
                let groupBatch = groups.filter { Set($0.members).isSubset(of: batchAddresses) }
                let job = Task.detached(priority: .utility) { () -> ([UUID: HUDAnchorMatch], [HUDAutomaticCandidate], [ControlBindingAddress: HUDAnchorMatch], [HUDGroupCandidate]) in
                    var matches: [UUID: HUDAnchorMatch] = [:]
                    for anchor in pending {
                        if Task.isCancelled { break }
                        guard let target = batch.first(where: { $0.address == anchor.address }) else { continue }
                        guard let original = map.hudTarget(at: anchor.address, aspect: anchor.referenceAspect) else { continue }
                        let scale = Double(target.transform.size) * max(1, start.aspect)
                            / (Double(original.transform.size) * max(1, anchor.referenceAspect))
                        let region = groupBatch.first(where: { $0.members.contains(anchor.address) })
                            .flatMap { HUDGroupSearch.region(for: $0, targets: batch, aspect: start.aspect) }
                        if let match = HUDAnchorMatcher.match(anchor, in: image,
                            expected: CGPoint(x: target.transform.xCoord, y: target.transform.yCoord),
                            scaleInHeights: scale, viewportAspect: start.aspect, searchBounds: region) {
                            matches[anchor.id] = match
                        }
                    }
                    let candidates = HUDAutomaticDiscovery.discover(in: image, targets: discoveryTargets,
                        aspect: start.aspect, maximumTargets: batchLimit)
                    var enrollmentMatches: [ControlBindingAddress: HUDAnchorMatch] = [:]
                    for candidate in candidates {
                        if Task.isCancelled { break }
                        let reference = enrollment[candidate.anchor.address]?.candidate ?? candidate
                        if let match = HUDAnchorMatcher.match(reference.anchor, in: image,
                            expected: reference.point, scaleInHeights: 1, searchRadiusInHeights: 0.055,
                            viewportAspect: start.aspect) {
                            enrollmentMatches[candidate.anchor.address] = match
                        }
                    }
                    var groupCandidates: [HUDGroupCandidate] = []
                    var bootstrapped = false
                    for group in groupBatch {
                        if Task.isCancelled { break }
                        guard let discovered = GenshinHUDLayoutAdapter.discover(in: image, map: map, group: group,
                            targets: baseTargets, aspect: start.aspect) else {
                            if !bootstrapped, group.members.contains(where: { !anchorAddresses.contains($0) }) {
                                bootstrapped = true
                                if let generic = HUDGroupBootstrap.discover(group: group, targets: batch, image: image, aspect: start.aspect) {
                                    groupCandidates.append(HUDGroupCandidate(group: group, points: generic.points,
                                        confidence: generic.confidence, regime: "mapped", anchors: generic.anchors, reflow: false))
                                }
                            }
                            continue
                        }
                        var references: [ControlHUDAnchor] = []
                        for point in discovered.points where point.available {
                            guard let target = map.hudTarget(at: point.address, aspect: start.aspect),
                                  let patch = HUDAnchorMatcher.template(in: image, center: point.point, spanInHeights: 0.065) else { continue }
                            let reference = ControlHUDAnchor(address: point.address, bindingSignature: target.bindingSignature,
                                referenceAspect: start.aspect, patchInHeights: 0.065, image: patch,
                                captureAspect: start.pointAspect)
                            guard let match = HUDAnchorMatcher.match(reference, in: image, expected: point.point,
                                scaleInHeights: 1, searchRadiusInHeights: 0.055, viewportAspect: start.aspect), match.isConfident,
                                  hypot(Double(match.point.x - point.point.x) * start.pointAspect,
                                        Double(match.point.y - point.point.y)) < 0.007 else { continue }
                            references.append(reference)
                        }
                        guard references.count == discovered.points.filter(\.available).count else { continue }
                        groupCandidates.append(HUDGroupCandidate(group: group, points: discovered.points,
                            confidence: discovered.confidence, regime: discovered.regime, anchors: references, reflow: true))
                    }
                    return (matches, candidates, enrollmentMatches, groupCandidates)
                }
                let (matches, candidates, enrollmentMatches, groupCandidates) = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
                guard !Task.isCancelled, generation == self.epoch, self.canTrack(), self.snapshot() == start else { return }
                for anchor in pending {
                    guard let match = matches[anchor.id], match.isConfident else {
                        prior[anchor.id] = nil
                        self.groupEvidence[anchor.address] = nil; self.groupConfidence[anchor.address] = nil
                        self.confidence[anchor.id] = matches[anchor.id]?.confidence ?? 0
                        self.states[anchor.id] = "Waiting for a clear HUD; map layout retained"
                        self.restoreMapPosition(anchor.address, aspect: start.aspect)
                        if self.automaticReferences[anchor.address]?.id == anchor.id {
                            let misses = (self.referenceMisses[anchor.id] ?? 0) + 1
                            self.referenceMisses[anchor.id] = misses
                            if misses >= 6 {
                                // Changed/hidden glyphs must not permanently block discovery.
                                // Manual overrides are retained until the user edits them.
                                self.automaticReferences[anchor.address] = nil
                                self.referenceMisses[anchor.id] = nil
                                self.states[anchor.id] = nil; self.confidence[anchor.id] = nil
                                self.referencesDirty = true
                                anchors.removeAll { $0.id == anchor.id }
                                if let group = groups.first(where: { $0.members.contains(anchor.address) }) {
                                    self.layoutSolver?.invalidateVerification(for: group.id)
                                    self.publish(group: group, points: nil, sample: nil)
                                }
                            }
                        }
                        continue
                    }
                    self.referenceMisses[anchor.id] = nil
                    self.confidence[anchor.id] = match.confidence
                    if let previous = prior[anchor.id], previous.isConfident,
                       hypot(Double(match.point.x - previous.point.x) * start.pointAspect,
                             Double(match.point.y - previous.point.y)) <= 0.009 {
                        self.adopt(match.point, address: anchor.address, anchorID: anchor.id, sample: start)
                        verified.insert(anchor.id)
                    } else { self.states[anchor.id] = "Checking a second frame" }
                    prior[anchor.id] = match
                }
                let visibleAddresses = Set(candidates.map { $0.anchor.address })
                observations = observations.filter { visibleAddresses.contains($0.key) }
                for candidate in candidates {
                    let address = candidate.anchor.address
                    guard let match = enrollmentMatches[address], match.isConfident,
                          hypot(Double(match.point.x - candidate.point.x) * start.pointAspect,
                                Double(match.point.y - candidate.point.y)) <= 0.007 else {
                        observations[address] = nil; continue
                    }
                    if var observation = observations[address],
                       abs(log(candidate.anchor.patchInHeights / observation.candidate.anchor.patchInHeights)) < 0.15,
                       hypot(Double(observation.candidate.point.x - candidate.point.x) * start.pointAspect,
                             Double(observation.candidate.point.y - candidate.point.y)) <= 0.007 {
                        observation.passes += 1; observations[address] = observation
                        if observation.passes >= 3, self.automaticReferences.count < ControlHUDAnchor.maximumCount {
                            let anchor = observation.candidate.anchor
                            self.automaticReferences[address] = anchor
                            self.referencesDirty = true
                            self.confidence[anchor.id] = min(match.confidence, candidate.shapeConfidence)
                            self.adopt(match.point, address: address, anchorID: anchor.id, sample: start)
                            anchors.append(anchor); verified.insert(anchor.id)
                            observations[address] = nil
                        }
                    } else { observations[address] = Observation(candidate: candidate, passes: 1) }
                }
                self.flushGroupEvidence(map: map, sample: start)
                let visibleGroups = Set(groupCandidates.map { $0.group.id })
                groupPrior = groupPrior.filter { visibleGroups.contains($0.key) }
                for candidate in groupCandidates {
                    let previous = groupPrior[candidate.group.id]
                    let agrees = previous.map { old in
                        old.candidate.regime == candidate.regime && zip(old.candidate.points, candidate.points).allSatisfy {
                            $0.0.address == $0.1.address && $0.0.available == $0.1.available
                                && hypot(($0.0.x - $0.1.x) * start.pointAspect, $0.0.y - $0.1.y) < 0.007
                        }
                    } ?? false
                    let passes = agrees ? (previous?.passes ?? 0) + 1 : 1
                    groupPrior[candidate.group.id] = (candidate, passes)
                    guard passes == 3,
                          let resolution = self.layoutSolver?.observe(group: candidate.group, points: candidate.points, map: map,
                            aspect: start.aspect, pointAspect: start.pointAspect, confidence: candidate.confidence,
                            regime: candidate.regime, reflow: candidate.reflow, revision: start.revision) else { continue }
                    for anchor in candidate.anchors {
                        if self.automaticReferences[anchor.address] != nil || self.automaticReferences.count < ControlHUDAnchor.maximumCount {
                            if let old = self.automaticReferences[anchor.address] {
                                self.states[old.id] = nil; self.confidence[old.id] = nil; self.referenceMisses[old.id] = nil
                            }
                            self.automaticReferences[anchor.address] = anchor
                            self.states[anchor.id] = "Verified HUD group"; self.confidence[anchor.id] = candidate.confidence
                        }
                    }
                    self.groupEvidence = self.groupEvidence.filter { !candidate.group.members.contains($0.key) }
                    self.groupConfidence = self.groupConfidence.filter { !candidate.group.members.contains($0.key) }
                    self.referencesDirty = true
                    self.publish(group: candidate.group, points: resolution.points, sample: start)
                }
                if attempt < 3 { try? await Task.sleep(for: .milliseconds(300)) }
            }
            guard !Task.isCancelled, generation == self.epoch else { return }
            self.nativeVerifiedAddresses.formUnion(nativeVerified)
            if showResult {
                self.notice("Automatic HUD alignment", "\(verified.count + nativeVerified.count) control(s) verified in this pass. Other controls keep the map layout and will be checked automatically as their HUD becomes visible.", false)
            }
        }
    }

    private func adopt(_ point: CGPoint, address: ControlBindingAddress, anchorID: UUID?, sample: Snapshot) {
        let effective = map.map { Set(ControlBindingGraph($0).effectiveBindings(activeLayer: activeLayer()).map(\.address)) } ?? []
        if activeGroups.contains(where: { $0.members.contains(address) && Set($0.members).isSubset(of: effective) }) {
            groupEvidence[address] = HUDLayoutPoint(address: address, point: point)
            groupConfidence[address] = anchorID.flatMap { confidence[$0] } ?? 1
            return
        }
        if actions[address]?.applyHUDPosition(point, aspect: sample.aspect) == true {
            pendingPositions[address] = nil
            if let anchorID { states[anchorID] = "Verified automatically" }
        } else {
            if let anchorID { states[anchorID] = "Waiting for held control release" }
            pendingPositions[address] = PendingPosition(point: point, snapshot: sample, anchorID: anchorID,
                deadline: .now + .seconds(3))
        }
    }

    /// Caller first saves/closes the editor and pauses mapped input. Capture no editor glyphs.
    func confirm(target: HUDControlTarget, spanInHeights: Double,
                 finish: @escaping (ControlHUDAnchor?, String?) -> Void) {
        cancel()
        let generation = epoch
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if generation == self.epoch { self.task = nil } }
            // Existing editor/save notices expire before sampling a clean HUD.
            try? await Task.sleep(for: .milliseconds(4500))
            guard !Task.isCancelled, generation == self.epoch, let start = self.snapshot() else {
                finish(nil, "HUD confirmation cancelled. Try again with a stable game window."); return
            }
            let capture = await self.capture(start, requestPermission: true)
            guard !Task.isCancelled, generation == self.epoch, self.snapshot() == start else {
                finish(nil, "HUD confirmation cancelled because the game window changed."); return
            }
            guard let image = capture.image else { finish(nil, capture.error); return }
            guard let patch = HUDAnchorMatcher.template(in: image,
                center: CGPoint(x: target.transform.xCoord, y: target.transform.yCoord), spanInHeights: spanInHeights) else {
                finish(nil, "The selected area has no clear HUD detail. Show the button or joystick ring, center the control on it, and confirm again."); return
            }
            // A reference must already identify its own control uniquely in the local area.
            let anchor = ControlHUDAnchor(address: target.address, bindingSignature: target.bindingSignature,
                referenceAspect: start.aspect, patchInHeights: spanInHeights, image: patch,
                captureAspect: start.pointAspect)
            let job = Task.detached(priority: .utility) {
                HUDAnchorMatcher.match(anchor, in: image,
                    expected: CGPoint(x: target.transform.xCoord, y: target.transform.yCoord),
                    scaleInHeights: 1, viewportAspect: start.aspect)
            }
            let match = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard !Task.isCancelled, generation == self.epoch, self.snapshot() == start else {
                finish(nil, "HUD confirmation cancelled because the game window changed."); return
            }
            guard let match, match.isConfident,
                  hypot(Double(match.point.x - target.transform.xCoord) * start.pointAspect,
                        Double(match.point.y - target.transform.yCoord)) < 0.012 else {
                finish(nil, "This HUD patch is ambiguous. Select a distinct visible button or joystick ring and confirm again."); return
            }
            self.task = nil
            finish(anchor, nil)
        }
    }

    private struct Capture: Sendable { let image: HUDGrayImage?; let error: String? }
    private func capture(_ sample: Snapshot, requestPermission: Bool) async -> Capture {
        guard bridge.responds(to: #selector(MacBridge.captureGameHUD(in:requestPermission:completion:))) else {
            return Capture(image: nil, error: "This runtime bridge does not support HUD capture. Relaunch with the current Mulg runtime.")
        }
        let token = beginCapture()
        defer { endCapture(token) }
        // Let compositing remove wrapper notices before capturing the real game HUD.
        try? await Task.sleep(for: .milliseconds(80))
        guard !Task.isCancelled, snapshot() == sample else {
            return Capture(image: nil, error: "The game geometry changed during capture.")
        }
        return await withCheckedContinuation { continuation in
            bridge.captureGameHUD?(in: sample.rect, requestPermission: requestPermission) { bytes, width, height, error in
                let image = bytes.map { HUDGrayImage(width: width, height: height, pixels: $0) }
                guard let image, image.isValid,
                      abs(Double(width) / Double(height) / sample.pointAspect - 1) < 0.01 else {
                    continuation.resume(returning: Capture(image: nil, error: error ?? "The captured surface has uncertain proportions.")); return
                }
                continuation.resume(returning: Capture(image: image, error: nil))
            }
        }
    }

    static func currentSnapshot(metrics: ScreenMetrics) -> Snapshot? {
        let viewport = GameViewport.shared
        guard let surface = viewport.captureSurface(), surface.isValid, surface.geometryIsCurrent,
              viewport.layer != nil, surface.window.bounds.width > 0, surface.window.bounds.height > 0,
              abs(surface.transform.b) < 0.0001, abs(surface.transform.c) < 0.0001,
              surface.transform.a > 0, surface.transform.d > 0 else { return nil }
        let origin = surface.windowPoint(.zero), end = surface.windowPoint(CGPoint(x: surface.bounds.width, y: surface.bounds.height))
        let size = surface.window.bounds.size
        let rect = CGRect(x: origin.x / size.width, y: origin.y / size.height,
            width: (end.x - origin.x) / size.width, height: (end.y - origin.y) / size.height)
        guard rect.width > 0, rect.height > 0, rect.minX >= -0.0001, rect.minY >= -0.0001,
              rect.maxX <= 1.0001, rect.maxY <= 1.0001 else { return nil }
        let boundedRect = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return Snapshot(revision: viewport.geometryRevision, rect: boundedRect,
            aspect: metrics.renderAspect, pointAspect: Double(surface.bounds.width / surface.bounds.height))
    }
}
#endif
