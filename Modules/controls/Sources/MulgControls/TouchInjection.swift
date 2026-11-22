import CoreGraphics
import Foundation
import MulgControlsHooks
import MulgEngine
import MulgContracts

public enum TouchPhase: Sendable, Equatable {
    case began, moved, ended
}

/// Injects touches into the game. The runtime uses the UIKit implementation; tests use a
/// recorder. Semantics follow upstream's `Toucher.touchcam`:
/// - `began` allocates an ID into `id` (and does nothing if `id` is already set);
/// - `moved` and `ended` need an ID and do nothing without one;
/// - after `ended`, `id` is nil.
@MainActor
public protocol TouchInjecting: AnyObject {
    /// The screen the game sees, in points (after the display module's changes).
    var screenBounds: CGRect { get }
    /// Presentation points plus the renderer's actual pixel aspect (never MetalFX input pixels).
    var screenMetrics: ScreenMetrics { get }
    func touch(_ id: inout Int?, at point: CGPoint, phase: TouchPhase)
    /// The neutral origin has actually reached UIKit, rather than only being queued.
    func hasDeliveredBegin(_ id: Int) -> Bool
    /// Returns once the contact's began phase has reached UIKit (true), or when the contact is gone
    /// or `timeout` passed first (false).
    func waitForBegin(_ id: Int, timeout: Duration) async -> Bool
    func cancel(_ id: inout Int?, at point: CGPoint)
    func cancelAll()
    func setSuspended(_ suspended: Bool)
    var deliveryDiagnostics: [String: Any] { get }
}

extension TouchInjecting {
    public var screenMetrics: ScreenMetrics { ScreenMetrics(bounds: screenBounds) }
    public func hasDeliveredBegin(_ id: Int) -> Bool { true }
    /// Polls; the UIKit injector is told by the delivery instead.
    public func waitForBegin(_ id: Int, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !hasDeliveredBegin(id) {
            guard ContinuousClock.now < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(8))
        }
        return true
    }
    public func cancel(_ id: inout Int?, at point: CGPoint) { touch(&id, at: point, phase: .ended) }
    public func cancelAll() {}
    public func setSuspended(_ suspended: Bool) {}
    public var deliveryDiagnostics: [String: Any] { [:] }
}

/// Each caller owns its deadline; a short wait must not fail another caller's
/// longer wait for the same contact. Actual begin/cancel delivery resolves all.
@MainActor
final class TouchBeginWaiters {
    private struct Waiter {
        let continuation: CheckedContinuation<Bool, Never>
        let timeout: Task<Void, Never>
    }
    private var pending: [Int: [UUID: Waiter]] = [:]
    var ids: [Int] { Array(pending.keys) }

    func wait(_ id: Int, timeout: Duration) async -> Bool {
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                let timer = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finish(id, token: token, delivered: false)
                }
                pending[id, default: [:]][token] = Waiter(continuation: continuation, timeout: timer)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, token: token, delivered: false) }
        }
    }

    private func finish(_ id: Int, token: UUID, delivered: Bool) {
        let waiter = pending[id]?.removeValue(forKey: token)
        if pending[id]?.isEmpty == true { pending.removeValue(forKey: id) }
        waiter?.timeout.cancel()
        waiter?.continuation.resume(returning: delivered)
    }

    func resolve(_ id: Int, delivered: Bool) {
        guard let waiters = pending.removeValue(forKey: id) else { return }
        for waiter in waiters.values {
            waiter.timeout.cancel()
            waiter.continuation.resume(returning: delivered)
        }
    }
}

#if canImport(UIKit) && !os(watchOS)
import UIKit

/// Injects real UIKit touches through the Objective-C injector.
///
/// Unlike upstream, which kept one global key window and hit-test view for every touch (so a
/// second finger could be sent to the first finger's view), each touch keeps its own: the injected
/// UITouch holds the window and view it began in.
@MainActor
public final class SystemTouchInjector: TouchInjecting {
    private struct Contact {
        let surface: GameViewport.Surface
        var localPoint: CGPoint
        var windowPoint: CGPoint
    }
    private var owners: [Int: Contact] = [:] {
        // A contact that is gone will never be delivered: its waiters stop waiting.
        didSet { for id in beginWaiters.ids where owners[id] == nil { resumeBegin(id, delivered: false) } }
    }
    private var suspended = false
    private var geometryCancellations = 0
    private let beginWaiters = TouchBeginWaiters()
    public init() {
        mulg_touch_prepare()
        mulg_touch_set_begin_handler { [weak self] id in
            MainActor.assumeIsolated { self?.resumeBegin(id, delivered: true) }
        }
    }

    public func waitForBegin(_ id: Int, timeout: Duration) async -> Bool {
        if hasDeliveredBegin(id) { return true }
        guard owners[id] != nil else { return false }
        return await beginWaiters.wait(id, timeout: timeout)
    }

    private func resumeBegin(_ id: Int, delivered: Bool) {
        beginWaiters.resolve(id, delivered: delivered)
    }

    public var screenBounds: CGRect {
        GameViewport.shared.bounds
    }
    public var screenMetrics: ScreenMetrics {
        ScreenMetrics(bounds: screenBounds, renderSize: GameViewport.shared.pixelSize)
    }

    public func touch(_ id: inout Int?, at point: CGPoint, phase: TouchPhase) {
        // Invalid movement/release coordinates must not abandon an existing
        // native contact. Cancel at the last valid captured position instead.
        guard point.x.isFinite, point.y.isFinite else {
            if phase != .began { cancel(&id, at: point) }
            return
        }
        switch phase {
        case .began:
            guard id == nil, !suspended,
                  let surface = GameViewport.shared.captureSurface(in: keyWindow()), surface.isValid else { return }
            let window = surface.window
            let converted = surface.windowPoint(point)
            guard converted.x.isFinite, converted.y.isFinite else { return }
            let hit = window.hitTest(converted, with: nil)
            guard let hit else { return }
            let result = mulg_touch_inject(-1, converted, .began, window, hit)
            if result >= 0 {
                id = result
                owners[result] = Contact(surface: surface, localPoint: point, windowPoint: converted)
            }
        case .moved:
            guard let current = id else { return }
            guard var contact = owners[current] else { id = nil; return }
            guard !suspended, contact.surface.geometryIsCurrent else {
                _ = mulg_touch_inject(current, contact.windowPoint, .cancelled, nil, nil)
                owners.removeValue(forKey: current)
                geometryCancellations += 1
                id = nil
                return
            }
            let converted = contact.surface.windowPoint(point)
            guard converted.x.isFinite, converted.y.isFinite else { cancel(&id, at: point); return }
            let result = mulg_touch_inject(current, converted, .moved, nil, nil)
            if result < 0 {
                id = nil
                owners.removeValue(forKey: current)
            } else {
                contact.localPoint = point
                contact.windowPoint = converted
                owners[current] = contact
            }
        case .ended:
            guard let current = id else { return }
            if let contact = owners[current] {
                let converted = contact.surface.windowPoint(point)
                let cancel = !contact.surface.geometryIsCurrent || !converted.x.isFinite || !converted.y.isFinite
                // A valid release includes the final cursor position, even when no
                // move event preceded it. A resized contact keeps its captured point.
                let finalPoint = cancel ? contact.windowPoint : converted
                _ = mulg_touch_inject(current, finalPoint, cancel ? .cancelled : .ended, nil, nil)
            }
            id = nil
            owners.removeValue(forKey: current)
        }
    }

    public func hasDeliveredBegin(_ id: Int) -> Bool { mulg_touch_begin_delivered(id) }

    public func cancel(_ id: inout Int?, at point: CGPoint) {
        guard let current = id else { return }
        if let contact = owners.removeValue(forKey: current) {
            _ = mulg_touch_inject(current, contact.windowPoint, .cancelled, nil, nil)
        }
        id = nil
    }

    public func cancelAll() {
        for (id, contact) in owners {
            _ = mulg_touch_inject(id, contact.windowPoint, .cancelled, nil, nil)
        }
        owners.removeAll()
    }

    public func setSuspended(_ suspended: Bool) {
        guard self.suspended != suspended else { return }
        self.suspended = suspended
        if suspended { cancelAll() }
    }

    public var deliveryDiagnostics: [String: Any] {
        var report = mulg_touch_delivery_diagnostics() as? [String: Any] ?? [:]
        report["suspended"] = suspended
        report["geometryCancellations"] = geometryCancellations
        report["coordinatePath"] = "render-surface → frozen-affine → UIKit-window → UIKit-view"
        report["ownedContacts"] = owners.sorted { $0.key < $1.key }.map { id, contact in
            ["id": Double(id), "localX": Double(contact.localPoint.x), "localY": Double(contact.localPoint.y),
             "windowX": Double(contact.windowPoint.x), "windowY": Double(contact.windowPoint.y),
             "a": Double(contact.surface.transform.a), "b": Double(contact.surface.transform.b),
             "c": Double(contact.surface.transform.c), "d": Double(contact.surface.transform.d)]
        }
        return report
    }

    private func keyWindow() -> UIWindow? {
        if let window = GameViewport.shared.window { return window }
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }
}
#endif
