import CoreGraphics
import Foundation
import MulgContracts

/// Something built from a keymap element that holds touches.
@MainActor
public protocol MulgAction: AnyObject {
    /// Lifts every touch this action holds.
    func invalidate()
    /// Buttons and key joysticks stay held across cursor/camera switches (§14.2).
    var isButtonLike: Bool { get }
    /// Only the map's selected persistent mouse-view action survives gameplay layer changes.
    var mouseViewRegistration: UInt64? { get }
    /// Reflow geometry without replacing handlers or dropping held-key ownership.
    func resize(to metrics: ScreenMetrics)
    /// Freeze joystick contacts for the complete native live-resize transaction.
    func setLiveResizing(_ resizing: Bool)
    func rebindSurface(to metrics: ScreenMetrics)
    /// One completed viewport transaction: adopt final geometry and restore logical holds.
    func commitViewport(to metrics: ScreenMetrics)
    /// Coalesce logical changes before publishing the final movement vector.
    func beginInputTransaction()
    /// Lift neutral old contacts before any transferred contact begins.
    func flushInputReleases()
    func endInputTransaction()
    /// Current numeric input geometry, for the existing throttled diagnostics report.
    var inputDiagnostics: [String: Double]? { get }
    /// Button/skill contacts whose current hold must survive camera recovery.
    var hasActiveGameplayTouch: Bool { get }
    /// Visual positions can only be adopted between contacts. nil restores the original map.
    func applyHUDPosition(_ point: CGPoint?, aspect: Double) -> Bool
    /// Preflight permits the HUD tracker to publish a complete group without partial adoption.
    var canApplyHUDPosition: Bool { get }
    func applyHUDLayout(_ point: CGPoint?, size: CGFloat?, available: Bool, aspect: Double) -> Bool
}

extension MulgAction {
    public var mouseViewRegistration: UInt64? { nil }
    public var inputDiagnostics: [String: Double]? { nil }
    public var hasActiveGameplayTouch: Bool { false }
    public func applyHUDPosition(_ point: CGPoint?, aspect: Double) -> Bool { false }
    public var canApplyHUDPosition: Bool { false }
    public func applyHUDLayout(_ point: CGPoint?, size: CGFloat?, available: Bool, aspect: Double) -> Bool {
        applyHUDPosition(point, aspect: aspect)
    }
    public func resize(to metrics: ScreenMetrics) {}
    public func setLiveResizing(_ resizing: Bool) {}
    public func beginInputTransaction() {}
    public func flushInputReleases() {}
    public func endInputTransaction() {}
    public func rebindSurface(to metrics: ScreenMetrics) {
        invalidate()
        resize(to: metrics)
    }
    public func commitViewport(to metrics: ScreenMetrics) {
        resize(to: metrics)
        setLiveResizing(false)
    }
}

private struct ActionGeometry {
    let transform: KeyModelTransform
    private var joystick: JoystickElement?
    private var hudPosition: CGPoint?
    private var hudSize: CGFloat?
    private var hudAspect: Double = 0
    var aspect: Double
    var metrics: ScreenMetrics {
        didSet {
            if metrics != oldValue { hudPosition = nil; hudSize = nil }
            // Older maps may activate before the first window has usable dimensions.
            if aspect <= 0, metrics.width > 0, metrics.height > 0 {
                aspect = metrics.renderAspect
            }
        }
    }
    init(_ transform: KeyModelTransform, _ metrics: ScreenMetrics, aspect: Double? = nil) {
        self.transform = transform
        self.metrics = metrics
        let fallback = metrics.width > 0 && metrics.height > 0 ? metrics.renderAspect : 0
        self.aspect = aspect.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? fallback
    }
    init(_ element: JoystickElement, _ metrics: ScreenMetrics, aspect: Double? = nil) {
        self.init(element.transform, metrics, aspect: aspect)
        joystick = element
    }
    var fitted: KeyModelTransform {
        let target = metrics.renderAspect
        var fitted = joystick?.calibratedTransform(forAspect: target) ?? transform.fitted(from: aspect, to: target)
        if let point = hudPosition, abs(target - hudAspect) < 0.000001 {
            fitted.xCoord = point.x; fitted.yCoord = point.y
            if let hudSize { fitted.size = hudSize }
        }
        return fitted
    }

    mutating func setHUDPosition(_ point: CGPoint?, aspect: Double) {
        hudPosition = point; hudAspect = aspect; hudSize = nil
    }
    mutating func setHUDLayout(_ point: CGPoint?, size: CGFloat?, aspect: Double) {
        hudPosition = point; hudAspect = aspect
        hudSize = size.flatMap { $0.isFinite && $0 > 0 && $0 <= 100 ? $0 : nil }
    }

    var point: CGPoint { metrics.point(fitted) }
    /// Points near the two ends of a long button's drawn shape (none for round or square ones): the centres
    /// of the round caps of a pill of that size, so every touch stays inside the shape.
    var shapeEndPoints: [CGPoint] {
        let fitted = fitted
        let base = metrics.size(fitted.size)
        let width = base * fitted.effectiveWidthScale, height = base * fitted.effectiveHeightScale
        let long = max(width, height), short = min(width, height)
        guard short > 0, long.isFinite, long >= short * 1.6 else { return [] }
        let centre = metrics.point(fitted), reach = (long - short) / 2
        return width >= height
            ? [CGPoint(x: centre.x - reach, y: centre.y), CGPoint(x: centre.x + reach, y: centre.y)]
            : [CGPoint(x: centre.x, y: centre.y - reach), CGPoint(x: centre.x, y: centre.y + reach)]
    }
    var size: CGFloat { metrics.size(fitted.size) }
    var hudSampleCount: Double { Double(transform.hudSamples?.count ?? 0) }
    var inputScale: CGFloat {
        KeymapCanvas(referenceAspectRatio: aspect,
            viewportAspectRatio: metrics.renderAspect)?
            .inputScale(viewportHeight: metrics.height) ?? 1
    }
}

extension ScreenMetrics {
    func point(_ transform: KeyModelTransform) -> CGPoint {
        CGPoint(x: transform.xCoord * width, y: transform.yCoord * height)
    }
}

// MARK: - Button

/// A key that taps a point (upstream ButtonAction).
@MainActor
public class ButtonAction: MulgAction {
    let injector: any TouchInjecting
    var point: CGPoint
    private var geometry: ActionGeometry
    let keyName: String
    var touchID: Int?
    let toggles: Bool
    private let tapDuration: Double?
    private var tapTask: Task<Void, Never>?
    private var tapKeyDown = false
    private var held = false
    private var liveResizing = false
    private var resizeSettling = false
    private var resumeTask: Task<Void, Never>?
    var hudAvailable = true

    public var isButtonLike: Bool { true }
    public var hasActiveGameplayTouch: Bool { touchID != nil }

    /// A long button (one drawn much wider than tall, or the reverse) also touches near both ends at once, so
    /// a game control anywhere along it counts as pressed (2026-11-28 user request: a long Genshin party-slot
    /// key never reached the burst icon beside the slot, as only its centre was touched). Round and square
    /// buttons keep the single centre touch.
    var spreadsAlongShape: Bool { true }
    private var shapeTouchIDs: [Int?] = []
    private var shapePoints: [CGPoint] { spreadsAlongShape ? geometry.shapeEndPoints : [] }

    func contact(_ phase: TouchPhase) {
        let began = phase == .began
        if began, touchID != nil { return }
        injector.touch(&touchID, at: point, phase: phase)
        if began {
            guard touchID != nil else { return }
            shapeTouchIDs = shapePoints.map { _ in nil }
        }
        let points = shapePoints
        for index in shapeTouchIDs.indices where index < points.count {
            injector.touch(&shapeTouchIDs[index], at: points[index], phase: phase)
        }
        if !began { cancelShapeContacts(points) }
    }

    func cancelContacts() {
        injector.cancel(&touchID, at: point)
        cancelShapeContacts(shapePoints)
    }

    private func cancelShapeContacts(_ points: [CGPoint]) {
        for index in shapeTouchIDs.indices where shapeTouchIDs[index] != nil {
            injector.cancel(&shapeTouchIDs[index], at: index < points.count ? points[index] : point)
        }
        shapeTouchIDs = []
    }

    public func applyHUDPosition(_ point: CGPoint?, aspect: Double) -> Bool {
        guard canApplyHUDPosition else { return false }
        geometry.setHUDPosition(point, aspect: aspect)
        hudAvailable = true
        self.point = geometry.point
        return true
    }
    public var canApplyHUDPosition: Bool { !held && !tapKeyDown && touchID == nil && !liveResizing && !resizeSettling }
    public func applyHUDLayout(_ point: CGPoint?, size: CGFloat?, available: Bool, aspect: Double) -> Bool {
        guard canApplyHUDPosition else { return false }
        geometry.setHUDLayout(point, size: size, aspect: aspect)
        hudAvailable = available; self.point = geometry.point
        return true
    }

    public init(element: ButtonElement, metrics: ScreenMetrics, injector: any TouchInjecting, dispatcher: ActionDispatcher,
                referenceAspect: Double? = nil) {
        self.injector = injector
        geometry = ActionGeometry(element.transform, metrics, aspect: referenceAspect)
        self.point = geometry.point
        self.keyName = element.keyName
        self.toggles = element.toggle ?? false
        tapDuration = element.tapDurationMilliseconds.flatMap { $0.isFinite && $0 > 0 ? min(250, max(16, $0)) : nil }
        // Upstream registers controller buttons (default code) by their stored name and keys by
        // the name of their code.
        guard let name = element.bindingName else { return }
        dispatcher.register(key: name, renewsCamera: true) { [weak self] pressed in
            self?.update(pressed: pressed)
        }
    }

    /// Subclasses can move their held drag from the old anchor without a spurious button tap.
    func reflowPoint(to metrics: ScreenMetrics, clearHUD: Bool = false) -> CGFloat {
        let previousScale = geometry.inputScale
        if clearHUD || metrics != geometry.metrics { hudAvailable = true }
        if clearHUD { geometry.setHUDPosition(nil, aspect: 0) }
        geometry.metrics = metrics
        point = geometry.point
        return geometry.inputScale / max(0.000001, previousScale)
    }

    var relativeInputScale: CGFloat { geometry.inputScale }
    var relativeInputScaleX: CGFloat { geometry.inputScale * geometry.metrics.horizontalUnitScale }
    public var inputDiagnostics: [String: Double]? {
        ["kind": 1, "pointX": Double(point.x), "pointY": Double(point.y),
         "renderAspect": geometry.metrics.renderAspect, "referenceAspect": geometry.aspect,
         "hudSamples": geometry.hudSampleCount]
    }

    public func resize(to metrics: ScreenMetrics) {
        tapTask?.cancel()
        tapTask = nil
        cancelContacts()
        geometry.setHUDPosition(nil, aspect: 0)
        _ = reflowPoint(to: metrics)
        settleContact()
    }
    public func rebindSurface(to metrics: ScreenMetrics) {
        resize(to: metrics)
    }
    public func commitViewport(to metrics: ScreenMetrics) {
        resumeTask?.cancel()
        resumeTask = nil
        tapTask?.cancel()
        tapTask = nil
        cancelContacts()
        _ = reflowPoint(to: metrics, clearHUD: true)
        hudAvailable = true
        liveResizing = false
        resizeSettling = false
        if held, tapDuration == nil { injector.touch(&touchID, at: point, phase: .began) }
    }
    public func setLiveResizing(_ resizing: Bool) {
        guard liveResizing != resizing else { return }
        liveResizing = resizing
        tapTask?.cancel()
        tapTask = nil
        cancelContacts()
        settleContact()
    }
    private func settleContact() {
        resizeSettling = true
        resumeTask?.cancel()
        resumeTask = nil
        guard !liveResizing else { return }
        resumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled, let self else { return }
            self.resizeSettling = false
            self.resumeTask = nil
            if self.held, self.tapDuration == nil {
                self.contact(.began)
            }
        }
    }
    func update(pressed: Bool) {
        if pressed && !hudAvailable { return }
        if toggles {
            // Hold-to-toggle: each press flips the touch; releases do nothing.
            guard pressed else { return }
            held.toggle()
            guard !liveResizing, !resizeSettling else { return }
            contact(held ? .began : .ended)
            // A refused begin did not latch anything in the game. Let the next
            // press retry, rather than spending it toggling an invisible hold off.
            if held && touchID == nil { held = false }
            return
        }
        if let tapDuration {
            guard tapKeyDown != pressed else { return }
            tapKeyDown = pressed
            // Key-up does not truncate the touch before a game frame can sample it.
            guard pressed, touchID == nil, !liveResizing, !resizeSettling else { return }
            contact(.began)
            guard let contactID = touchID else { return }
            tapTask = Task { @MainActor [weak self, tapDuration, contactID] in
                // The tap's length counts from when UIKit has the touch, not from when it was queued.
                guard let injector = self?.injector else { return }
                let delivered = await injector.waitForBegin(contactID, timeout: .seconds(2))
                guard !Task.isCancelled, let self, self.touchID == contactID else { return }
                if !delivered { self.invalidate(); return }
                try? await Task.sleep(for: .milliseconds(tapDuration))
                guard !Task.isCancelled, self.touchID == contactID else { return }
                self.tapTask = nil
                self.contact(.ended)
            }
        } else {
            held = pressed
            guard !liveResizing, !resizeSettling else { return }
            contact(pressed ? .began : .ended)
        }
    }

    public func invalidate() {
        resumeTask?.cancel()
        resumeTask = nil
        held = false
        resizeSettling = liveResizing
        tapTask?.cancel()
        tapTask = nil
        tapKeyDown = false
        cancelContacts()
    }
}

/// A grab binding that follows its selected mouse/controller motion source until released.
@MainActor
public final class DraggableButtonAction: ButtonAction {
    private var releasePoint: CGPoint
    private weak var dispatcher: ActionDispatcher?
    private var dragSuspended = false
    private let motionSource: String
    private var motionRegistration: UInt64?

    public override var isButtonLike: Bool { false }
    override var spreadsAlongShape: Bool { false }
    public override var canApplyHUDPosition: Bool { !dragSuspended && super.canApplyHUDPosition }

    public override init(element: ButtonElement, metrics: ScreenMetrics, injector: any TouchInjecting, dispatcher: ActionDispatcher,
                referenceAspect: Double? = nil) {
        releasePoint = .zero
        motionSource = element.dragMotionBindingName
        self.dispatcher = dispatcher
        super.init(element: element, metrics: metrics, injector: injector, dispatcher: dispatcher,
            referenceAspect: referenceAspect)
        releasePoint = point
    }

    public override func resize(to metrics: ScreenMetrics) {
        invalidate()
        _ = reflowPoint(to: metrics, clearHUD: true)
        releasePoint = point
    }
    public override func setLiveResizing(_ resizing: Bool) {
        dragSuspended = resizing
        if resizing { invalidate() }
    }
    public override func rebindSurface(to metrics: ScreenMetrics) {
        resize(to: metrics)
    }
    public override func commitViewport(to metrics: ScreenMetrics) {
        resize(to: metrics)
        setLiveResizing(false)
    }
    override func update(pressed: Bool) {
        if pressed && !hudAvailable { return }
        if pressed {
            guard !dragSuspended, touchID == nil else { return }
            injector.touch(&touchID, at: point, phase: .began)
            guard touchID != nil else { return }
            releasePoint = point
            motionRegistration = dispatcher?.register(key: motionSource, priority: .draggable) { [weak self] dx, dy in
                self?.mouseMoved(dx: dx, dy: dy)
            }
        } else {
            injector.touch(&touchID, at: releasePoint, phase: .ended)
            if touchID == nil {
                removeMotionRegistration()
            }
        }
    }

    private func removeMotionRegistration() {
        if let motionRegistration { dispatcher?.unregister(registration: motionRegistration) }
        motionRegistration = nil
    }

    func mouseMoved(dx: CGFloat, dy: CGFloat) {
        releasePoint.x += dx * relativeInputScaleX
        releasePoint.y -= dy * relativeInputScale
        injector.touch(&touchID, at: releasePoint, phase: .moved)
        // Geometry changes can cancel the contact inside the injector. A dead
        // drag must stop winning the dispatcher over the remaining motion paths.
        if touchID == nil { removeMotionRegistration() }
    }

    /// Lifts where the drag reached. Cursor visibility/capture belongs solely to the router.
    public override func invalidate() {
        injector.cancel(&touchID, at: releasePoint)
        super.invalidate()
        removeMotionRegistration()
    }
}

// MARK: - Joysticks

/// A stick owns a logical direction separately from its pixel contact. Resizing releases
/// the old contact once, waits for the game HUD to settle, then establishes a new neutral
/// origin. A direction never inherits any displacement from the previous viewport.
@MainActor
private final class JoystickContact {
    private let injector: any TouchInjecting
    private var geometry: ActionGeometry
    private var touchID: Int?
    private var point: CGPoint = .zero
    private var origin: CGPoint = .zero
    private var frame: JoystickContactFrame?
    /// Canonical controller axes: right +X, forward +Y.
    private var direction = CGVector.zero
    private var settling = false
    private var liveResizing = false
    private var settleTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    private var inputTransactionDepth = 0
    private var pendingDirection = false
    private let activationDelay: Double
    /// The floating-stick wait after touch-down counts the game's frames (two frame starts: one
    /// update that samples the origin, then the move) instead of a fixed 40 ms, with the fixed delay
    /// as the limit when no frames run. Build 912 instead kept the finger down at the center after a
    /// release; a stick whose base follows the finger read that center as a push backwards.
    private let framePacedActivation: Bool
    /// Floating sticks: the finger glides to its direction one game frame per step (at most a third
    /// of the radius each) and stays within `floatingReach` of the radius. A floating stick whose base
    /// follows the finger was dragged along by a full-radius jump (Ragnarok logged a contact 93 points
    /// from its origin on a 64-point stick), and some engines read a single teleport as a new tap.
    private let glides: Bool
    private var glideTask: Task<Void, Never>?
    static let floatingReach: CGFloat = 0.7

    init(element: JoystickElement, metrics: ScreenMetrics, injector: any TouchInjecting, referenceAspect: Double?,
         framePacedActivation: Bool = false, glide: Bool = false) {
        self.injector = injector
        self.framePacedActivation = framePacedActivation
        glides = glide
        geometry = ActionGeometry(element, metrics, aspect: referenceAspect)
        let configured = element.activationDelayMilliseconds.flatMap { value in
            value.isFinite ? min(100, max(0, value)) : nil
        }
        // Engines may sample a floating origin in their update loop rather than UIKit's
        // began callback. Keep that neutral sample separate from the deflected sample.
        activationDelay = configured ?? (element.effectiveMode == .FLOATING ? 40 : 0)
    }

    var diagnostics: [String: Double] {
        ["requestedX": Double(direction.dx), "requestedY": Double(direction.dy),
         "originX": Double(origin.x), "originY": Double(origin.y),
         "contactX": Double(point.x), "contactY": Double(point.y),
         "contactHeld": touchID == nil ? 0 : 1, "settling": settling ? 1 : 0,
         "kind": 2, "renderAspect": geometry.metrics.renderAspect,
         "hudSamples": geometry.hudSampleCount,
         "horizontalUnitScale": Double(frame?.horizontalScale ?? geometry.metrics.horizontalUnitScale),
         "travelRadius": Double(radius),
         "mappedX": Double(frame?.vector(at: point).dx ?? 0),
         "mappedY": Double(frame?.vector(at: point).dy ?? 0)]
    }
    var inputScale: CGFloat { geometry.inputScale }
    var canApplyHUDPosition: Bool { direction == .zero && touchID == nil && !settling && !liveResizing }
    func applyHUDPosition(_ point: CGPoint?, aspect: Double) -> Bool {
        guard canApplyHUDPosition else { return false }
        geometry.setHUDPosition(point, aspect: aspect)
        frame = nil
        return true
    }
    private var nextFrame: JoystickContactFrame? {
        JoystickContactFrame(center: geometry.point, requestedRadius: geometry.size / 4, metrics: geometry.metrics)
    }
    var radius: CGFloat { (frame ?? nextFrame)?.radius ?? 0 }

    func setDirection(_ value: CGVector) {
        guard value.dx.isFinite, value.dy.isFinite else {
            direction = .zero
            if inputTransactionDepth > 0 { pendingDirection = true; return }
            releaseContact(cancelled: true)
            return
        }
        let length = max(1, hypot(value.dx, value.dy))
        direction = CGVector(dx: value.dx / length, dy: value.dy / length)
        if inputTransactionDepth > 0 { pendingDirection = true; return }
        guard direction != .zero else { releaseContact(); return }
        guard !settling, !liveResizing else { return }
        applyDirection()
    }

    func beginInputTransaction() { inputTransactionDepth += 1 }
    func flushInputReleases() {
        if inputTransactionDepth == 1, pendingDirection, direction == .zero { releaseContact() }
    }
    func endInputTransaction() {
        guard inputTransactionDepth > 0 else { return }
        inputTransactionDepth -= 1
        guard inputTransactionDepth == 0, pendingDirection else { return }
        pendingDirection = false
        if direction == .zero { releaseContact(); return }
        if !settling, !liveResizing { applyDirection() }
    }

    func resize(to metrics: ScreenMetrics, replacingSurface: Bool = false) {
        guard replacingSurface || metrics != geometry.metrics else { return }
        // End at the last delivered location, before adopting the new coordinate space.
        releaseContact(cancelled: true)
        geometry.metrics = metrics
        settling = true
        scheduleResume()
    }

    func setLiveResizing(_ resizing: Bool) {
        guard liveResizing != resizing else { return }
        liveResizing = resizing
        releaseContact(cancelled: true)
        settling = true
        scheduleResume()
    }
    func commitViewport(to metrics: ScreenMetrics) {
        settleTask?.cancel()
        settleTask = nil
        releaseContact(cancelled: true)
        geometry.setHUDPosition(nil, aspect: 0)
        geometry.metrics = metrics
        liveResizing = false
        settling = false
        if direction != .zero { applyDirection() }
    }

    private func scheduleResume() {
        settleTask?.cancel()
        settleTask = nil
        guard !liveResizing else { return }
        // Coalesce continuous layout changes. In particular, never start a fresh floating
        // origin on every intermediate size while Unity is rebuilding its HUD.
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled, let self else { return }
            self.settleTask = nil
            self.settling = false
            if self.direction != .zero { self.applyDirection() }
        }
    }

    private func applyDirection() {
        guard radius > 0 else { releaseContact(); return }
        if touchID == nil {
            guard let capturedFrame = nextFrame else { return }
            frame = capturedFrame
            origin = capturedFrame.center
            point = origin
            injector.touch(&touchID, at: origin, phase: .began)
            guard let contactID = touchID else { frame = nil; return }
            activationTask = Task { @MainActor [weak self, activationDelay, framePacedActivation] in
                // A blocked main queue can delay touch delivery beyond a wall-clock
                // activation timer. Start that timer only after UIKit sees the center.
                guard let injector = self?.injector else { return }
                let delivered = await injector.waitForBegin(contactID, timeout: .seconds(2))
                guard !Task.isCancelled, let self, self.touchID == contactID else { return }
                if !delivered { self.releaseContact(); return }
                if activationDelay > 0 {
                    if framePacedActivation {
                        await FrameTicker.shared.wait(frames: 2, timeout: .milliseconds(activationDelay))
                    } else {
                        try? await Task.sleep(for: .milliseconds(activationDelay))
                    }
                }
                guard !Task.isCancelled, self.touchID == contactID,
                      self.frame == capturedFrame, !self.settling, !self.liveResizing else { return }
                self.activationTask = nil
                self.moveContact()
            }
            return
        }
        if activationTask == nil { moveContact() }
    }

    private func moveContact() {
        guard let frame, touchID != nil, direction != .zero else { return }
        guard glides else { step(to: frame.point(for: direction)); return }
        let reach = Self.floatingReach
        let target = frame.point(for: CGVector(dx: direction.dx * reach, dy: direction.dy * reach))
        glideTask?.cancel()
        glideTask = nil
        let start = point
        let distance = hypot(target.x - start.x, target.y - start.y)
        let steps = max(1, Int((distance / max(1, frame.radius / 3)).rounded(.up)))
        guard steps > 1 else { step(to: target); return }
        glideTask = Task { @MainActor [weak self] in
            for index in 1...steps {
                guard !Task.isCancelled, let self, self.touchID != nil else { return }
                let progress = CGFloat(index) / CGFloat(steps)
                self.step(to: CGPoint(x: start.x + (target.x - start.x) * progress,
                                      y: start.y + (target.y - start.y) * progress))
                if index < steps { await FrameTicker.shared.wait(frames: 1, timeout: .milliseconds(8)) }
            }
            guard !Task.isCancelled else { return }
            self?.glideTask = nil
        }
    }

    private func step(to target: CGPoint) {
        point = target
        injector.touch(&touchID, at: point, phase: .moved)
        // The injector can reject a stale/cancelled contact. Never keep its old frame.
        if touchID == nil { frame = nil }
    }

    private func releaseContact(cancelled: Bool = false) {
        activationTask?.cancel()
        activationTask = nil
        glideTask?.cancel()
        glideTask = nil
        if cancelled { injector.cancel(&touchID, at: point) }
        else { injector.touch(&touchID, at: point, phase: .ended) }
        frame = nil
    }

    func invalidate() {
        settleTask?.cancel()
        settleTask = nil
        releaseContact(cancelled: true)
        direction = .zero
        pendingDirection = false
        // Retain liveResizing/settling until the transaction completes; a focus change
        // must not allow a key to start a contact inside an unfinished resize.
        if settling, !liveResizing { scheduleResume() }
    }
}

/// Four keys drive a unit-circle vector; pixel contact state belongs to JoystickContact.
@MainActor
public final class KeyJoystickAction: MulgAction {
    private let contact: JoystickContact
    private var movement = DigitalJoystick()
    private var walking = false
    public var inputDiagnostics: [String: Double]? {
        var values = contact.diagnostics
        for direction in DigitalJoystick.Direction.allCases {
            values["held." + String(describing: direction)] = movement.isHeld(direction) ? 1 : 0
        }
        return values
    }
    public var isButtonLike: Bool { true }
    public var canApplyHUDPosition: Bool { contact.canApplyHUDPosition }

    public init(element: JoystickElement, metrics: ScreenMetrics, injector: any TouchInjecting, dispatcher: ActionDispatcher,
                referenceAspect: Double? = nil, framePacedActivation: Bool = false, glide: Bool = false) {
        contact = JoystickContact(element: element, metrics: metrics, injector: injector, referenceAspect: referenceAspect,
                                  framePacedActivation: framePacedActivation, glide: glide)
        let keys = [element.upKeyCode, element.downKeyCode, element.leftKeyCode, element.rightKeyCode]
        for (index, code) in keys.enumerated() {
            guard let name = KeymapKeyNames.name(forKeyCode: code) else { continue }
            dispatcher.register(key: name, transfersMovement: true) { [weak self] in self?.keyChanged(index: index, pressed: $0) }
        }
    }

    public func resize(to metrics: ScreenMetrics) { contact.resize(to: metrics) }
    public func applyHUDPosition(_ point: CGPoint?, aspect: Double) -> Bool { contact.applyHUDPosition(point, aspect: aspect) }
    public func rebindSurface(to metrics: ScreenMetrics) { contact.resize(to: metrics, replacingSurface: true) }
    public func setLiveResizing(_ resizing: Bool) { contact.setLiveResizing(resizing) }
    public func commitViewport(to metrics: ScreenMetrics) { contact.commitViewport(to: metrics) }
    public func beginInputTransaction() { contact.beginInputTransaction() }
    public func flushInputReleases() { contact.flushInputReleases() }
    public func endInputTransaction() { contact.endInputTransaction() }

    func keyChanged(index: Int, pressed value: Bool) {
        guard let direction = DigitalJoystick.Direction(rawValue: index),
              movement.isHeld(direction) != value else { return }
        movement.set(direction, pressed: value)
        updateTarget()
    }

    public func setWalking(_ value: Bool) {
        guard walking != value else { return }
        walking = value
        updateTarget()
    }

    private func updateTarget() {
        contact.setDirection(movement.vector(magnitude: walking ? 0.35 : 1))
    }

    public func invalidate() {
        contact.invalidate()
        movement.reset()
        walking = false
    }
}

/// Mouse/controller sticks use the same contact lifecycle and circular direction geometry.
@MainActor
public final class AnalogJoystickAction: MulgAction {
    public private(set) var mouseViewRegistration: UInt64?
    private let contact: JoystickContact
    private var direction = CGVector.zero
    public var inputDiagnostics: [String: Double]? { contact.diagnostics }
    public var isButtonLike: Bool { false }
    public var canApplyHUDPosition: Bool { contact.canApplyHUDPosition }
    public func applyHUDPosition(_ point: CGPoint?, aspect: Double) -> Bool { contact.applyHUDPosition(point, aspect: aspect) }

    public init(element: JoystickElement, metrics: ScreenMetrics, injector: any TouchInjecting, dispatcher: ActionDispatcher,
                referenceAspect: Double? = nil) {
        contact = JoystickContact(element: element, metrics: metrics, injector: injector, referenceAspect: referenceAspect)
        if element.keyName == KeymapNames.mouseMove {
            mouseViewRegistration = dispatcher.register(key: element.keyName) { [weak self] dx, dy in self?.mouseMoved(dx: dx, dy: dy) }
        } else {
            dispatcher.register(key: element.keyName) { [weak self] x, y in self?.thumbstickMoved(x: x, y: y) }
        }
    }

    public func resize(to metrics: ScreenMetrics) {
        contact.resize(to: metrics)
        submitDirection()
    }
    public func setLiveResizing(_ resizing: Bool) { contact.setLiveResizing(resizing) }
    public func commitViewport(to metrics: ScreenMetrics) { contact.commitViewport(to: metrics) }
    public func beginInputTransaction() { contact.beginInputTransaction() }
    public func flushInputReleases() { contact.flushInputReleases() }
    public func endInputTransaction() { contact.endInputTransaction() }

    public func rebindSurface(to metrics: ScreenMetrics) {
        contact.resize(to: metrics, replacingSurface: true)
        submitDirection()
    }

    func thumbstickMoved(x: CGFloat, y: CGFloat) {
        guard x.isFinite, y.isFinite else { return }
        direction = CGVector(dx: x, dy: y)
        submitDirection()
    }

    func mouseMoved(dx: CGFloat, dy: CGFloat) {
        guard dx.isFinite, dy.isFinite else { return }
        let radius = contact.radius
        guard radius > 0 else { return }
        direction.dx += dx * contact.inputScale / radius
        direction.dy += dy * contact.inputScale / radius
        submitDirection()
    }

    private func submitDirection() {
        let length = max(1, hypot(direction.dx, direction.dy))
        direction = CGVector(dx: direction.dx / length, dy: direction.dy / length)
        let deadzone = min(0.95, 16 * contact.inputScale / max(1, contact.radius))
        contact.setDirection(hypot(direction.dx, direction.dy) < deadzone ? .zero : direction)
    }

    public func invalidate() {
        direction = .zero
        contact.invalidate()
    }
}
// MARK: - Camera and swipes

/// A touch that follows relative movement and lifts off by itself when movement stops
/// (upstream SwipeAction), keeping inside the screen so games don't drop it.
/// With `liftsWhenIdle` false the touch stays down while movement pauses: only the screen
/// edge, `liftOff` or a cancellation end it.
@MainActor
public final class SwipeAction {
    private let injector: any TouchInjecting
    private let metrics: () -> ScreenMetrics
    private let liftsWhenIdle: Bool
    private(set) var location: CGPoint = .zero
    private var touchID: Int?
    private var counter = 0
    private var lastCounter = 0
    private var shouldEdgeReset = false
    private var idleTask: Task<Void, Never>?

    /// A swipe needs at least this many events to get inertia in most games.
    static let minimumEvents = 16

    var isTouching: Bool { touchID != nil }

    init(injector: any TouchInjecting, liftsWhenIdle: Bool = true, metrics: @escaping () -> ScreenMetrics) {
        self.injector = injector
        self.liftsWhenIdle = liftsWhenIdle
        self.metrics = metrics
    }

    func move(from start: () -> CGPoint?, dx: CGFloat, dy: CGFloat) {
        let screen = metrics()
        guard dx.isFinite, dy.isFinite, screen.width.isFinite, screen.height.isFinite,
              screen.width > 0, screen.height > 0 else { return }
        if shouldEdgeReset {
            // The prediction used the previous packet's direction. A player may have
            // reversed since then; keep the existing contact if this packet stays inside.
            if screen.contains(CGPoint(x: location.x + dx, y: location.y - dy)) {
                shouldEdgeReset = false
            } else {
                liftOff()
            }
        }
        if touchID == nil {
            guard let origin = start(), screen.contains(origin) else { return }
            location = origin
            counter = 0
            injector.touch(&touchID, at: location, phase: .began)
            guard touchID != nil else { return }
            if liftsWhenIdle { startIdleCheck() }
        }
        var scaledX = dx
        var scaledY = dy
        if counter < Self.minimumEvents {
            // Slow down if the swipe would leave the screen before it has enough events.
            let remaining = CGFloat(Self.minimumEvents - counter)
            let predicted = CGPoint(x: location.x + remaining * dx, y: location.y - remaining * dy)
            if !screen.contains(predicted) {
                let scale = Self.velocityScale(predicted: predicted, now: location, screen: screen)
                scaledX *= scale
                scaledY *= scale
            }
        }
        counter += 1
        // A fast packet can cross the edge after the inertia warmup too. Keep
        // the sample inside the surface before considering the next movement.
        location.x = min(max(location.x + scaledX, 0), screen.width)
        location.y = min(max(location.y - scaledY, 0), screen.height)
        injector.touch(&touchID, at: location, phase: .moved)
        guard touchID != nil else { liftOff(); return }
        if !screen.contains(CGPoint(x: location.x + scaledX, y: location.y - scaledY)) {
            // A further movement out of bounds needs a new swipe; a reversal does not.
            shouldEdgeReset = true
        }
    }

    func reflow(from old: CGPoint, to new: CGPoint, scale: CGFloat) {
        guard touchID != nil else { return }
        let screen = metrics()
        location = CGPoint(x: min(max(new.x + (location.x - old.x) * scale, 0), screen.width),
                           y: min(max(new.y + (location.y - old.y) * scale, 0), screen.height))
        injector.touch(&touchID, at: location, phase: .moved)
    }
    /// Multiplier that keeps a predicted point inside the screen.
    static func velocityScale(predicted: CGPoint, now: CGPoint, screen: ScreenMetrics) -> CGFloat {
        var scale: CGFloat = 1
        if predicted.x < 0 {
            scale = min(scale, (0 - now.x) / (predicted.x - now.x))
        } else if predicted.x > screen.width {
            scale = min(scale, (screen.width - now.x) / (predicted.x - now.x))
        }
        if predicted.y < 0 {
            scale = min(scale, (0 - now.y) / (predicted.y - now.y))
        } else if predicted.y > screen.height {
            scale = min(scale, (screen.height - now.y) / (predicted.y - now.y))
        }
        return max(0, scale)
    }

    /// Lifts off after about half a second without movement (upstream checked every 0.1 s after
    /// counting to 4).
    private func startIdleCheck() {
        idleTask?.cancel()
        lastCounter = counter
        idleTask = Task { @MainActor [weak self] in
            var idleTicks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self, self.touchID != nil else { return }
                if self.counter == self.lastCounter {
                    idleTicks += 1
                    if idleTicks >= 5 {
                        self.liftOff()
                        return
                    }
                } else {
                    idleTicks = 0
                }
                self.lastCounter = self.counter
            }
        }
    }

    func liftOff(cancelled: Bool = false) {
        if cancelled { injector.cancel(&touchID, at: location) }
        else { injector.touch(&touchID, at: location, phase: .ended) }
        if touchID == nil {
            idleTask?.cancel()
            idleTask = nil
            shouldEdgeReset = false

        }
    }
}

/// Mouse movement over a camera area, and scroll-wheel zoom (upstream CameraAction).
@MainActor
public final class CameraAction: MulgAction {
    public private(set) var mouseViewRegistration: UInt64?
    private var suspended = false
    private var center: CGPoint
    private var geometry: ActionGeometry
    private let move: SwipeAction
    private let pinch: PinchZoom
    private let metrics: () -> ScreenMetrics
    private weak var dispatcher: ActionDispatcher?
    private static let gameplayRecoveryPause: Duration = .milliseconds(90)
    private var renewAfterGameplay = false
    private var lastMovement: ContinuousClock.Instant?
    private var gestureRenewals = 0

    public var isButtonLike: Bool { false }
    public var inputDiagnostics: [String: Double]? {
        ["kind": 3, "pointX": Double(center.x), "pointY": Double(center.y),
         "renderAspect": geometry.metrics.renderAspect, "referenceAspect": geometry.aspect,
         "hudSamples": geometry.hudSampleCount, "gestureRenewals": Double(gestureRenewals)]
    }

    public init(element: MouseAreaElement, metrics: ScreenMetrics, injector: any TouchInjecting,
                dispatcher: ActionDispatcher, liveMetrics: @escaping () -> ScreenMetrics,
                referenceAspect: Double? = nil) {
        geometry = ActionGeometry(element.transform, metrics, aspect: referenceAspect)
        center = geometry.point
        self.metrics = liveMetrics
        self.dispatcher = dispatcher
        // The view finger stays down while the mouse rests. Lifted after a pause, the next
        // movement began a new finger while an attack or skill touch was down, and a game
        // (Genshin) need not accept a view drag that begins during a button touch: the view
        // stopped turning after every attack or skill. Gameplay-boundary recovery,
        // mode changes, focus loss, resizing, zoom and actual screen edges can renew it.
        move = SwipeAction(injector: injector, liftsWhenIdle: false, metrics: liveMetrics)
        pinch = PinchZoom(injector: injector, metrics: liveMetrics)
        let registration = dispatcher.register(key: element.keyName, priority: .camera) { [weak self] dx, dy in
            self?.moved(dx: dx, dy: dy)
        }
        if element.keyName == KeymapNames.mouseMove { mouseViewRegistration = registration }
        dispatcher.register(key: KeymapNames.scrollWheelScale) { [weak self] _, dy in
            self?.zoom(dy: dy)
        }
    }

    public func resize(to metrics: ScreenMetrics) {
        // Moving an existing camera finger is interpreted as a look/zoom gesture.
        // End it without synthetic movement; the next real input uses the new canvas.
        invalidate()
        geometry.metrics = metrics
        center = geometry.point
    }
    func moved(dx: CGFloat, dy: CGFloat, at now: ContinuousClock.Instant = .now) {
        guard !suspended, dx != 0 || dy != 0 else { return }
        let paused = lastMovement.map { $0.duration(to: now) >= Self.gameplayRecoveryPause } ?? false
        lastMovement = now
        // A game may discard the camera gesture during a skill. Reacquire on the first
        // movement after a pause, with no skill touch down. Restarting on each attack
        // release interrupts a continuous sweep and repeatedly resets its touch origin.
        if renewAfterGameplay && paused && dispatcher?.hasActiveGameplayTouches != true {
            move.liftOff(cancelled: true)
            renewAfterGameplay = false
            gestureRenewals += 1
        }
        let center = self.center
        move.move(from: { center }, dx: dx * geometry.inputScale * geometry.metrics.horizontalUnitScale,
                  dy: dy * geometry.inputScale)
    }

    func gameplayInteractionFinished() { renewAfterGameplay = move.isTouching }

    /// Scroll to zoom: a two-finger pinch at the screen centre (PinchZoom).
    func zoom(dy: CGFloat) {
        guard !suspended, dy != 0 else { return }
        // The pinch's two fingers must not land beside a resting view finger (a third touch).
        if move.isTouching { move.liftOff() }
        renewAfterGameplay = false
        pinch.scroll(dy * geometry.inputScale)
    }

    public func invalidate() {
        renewAfterGameplay = false
        lastMovement = nil
        move.liftOff(cancelled: true)
        pinch.cancel()
    }
    public func setLiveResizing(_ resizing: Bool) {
        suspended = resizing
        if resizing { invalidate() }
    }
}

/// Scroll-wheel drag while the cursor is shown (upstream CameraAction.dragUpdated).
@MainActor
public final class ScrollDragAction: MulgAction {
    private let swipe: SwipeAction
    private let cursor: () -> CGPoint?
    private var suspended = false

    public var isButtonLike: Bool { false }

    public init(injector: any TouchInjecting, dispatcher: ActionDispatcher,
                liveMetrics: @escaping () -> ScreenMetrics, referenceAspect: Double? = nil,
                cursor: @escaping () -> CGPoint?) {
        swipe = SwipeAction(injector: injector, metrics: liveMetrics)
        let initial = liveMetrics()
        let canvasAspect = referenceAspect ?? initial.renderAspect
        self.cursor = cursor
        dispatcher.register(key: KeymapNames.scrollWheelDrag) { [weak self] dx, dy in
            guard let self, !self.suspended else { return }
            let metrics = liveMetrics()
            let scale = KeymapCanvas(referenceAspectRatio: canvasAspect,
                viewportAspectRatio: metrics.renderAspect)?
                .inputScale(viewportHeight: metrics.height) ?? 1
            self.swipe.move(from: self.cursor, dx: dx * 4 * scale * metrics.horizontalUnitScale, dy: -dy * 4 * scale)
        }
    }

    public func resize(to metrics: ScreenMetrics) { swipe.liftOff(cancelled: true) }
    public func setLiveResizing(_ resizing: Bool) {
        suspended = resizing
        if resizing { invalidate() }
    }

    public func invalidate() {
        swipe.liftOff(cancelled: true)
    }
}

// MARK: - Cursor clicks

/// Clicks and drags at the cursor while it is shown (upstream FakeMouseAction).
@MainActor
public final class FakeMouseAction: MulgAction {
    private let injector: any TouchInjecting
    private var touchID: Int?
    private var position: CGPoint = .zero
    private var suspended = false

    public var isButtonLike: Bool { false }

    public init(injector: any TouchInjecting) {
        self.injector = injector
    }

    public func press(at point: CGPoint) {
        guard !suspended, touchID == nil, point.x.isFinite, point.y.isFinite else { return }
        position = point
        injector.touch(&touchID, at: point, phase: .began)
    }

    public func drag(to point: CGPoint) {
        guard !suspended, touchID != nil, point.x.isFinite, point.y.isFinite else { return }
        position = point
        injector.touch(&touchID, at: point, phase: .moved)
    }

    public func release(at point: CGPoint? = nil) {
        if let point, point.x.isFinite, point.y.isFinite { position = point }
        injector.touch(&touchID, at: position, phase: .ended)
    }

    public func resize(to metrics: ScreenMetrics) { injector.cancel(&touchID, at: position) }
    public func setLiveResizing(_ resizing: Bool) {
        suspended = resizing
        if resizing { invalidate() }
    }

    public var isPressed: Bool { touchID != nil }

    public func invalidate() {
        injector.cancel(&touchID, at: position)
    }
}
