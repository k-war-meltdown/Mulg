import Foundation

/// Something one module tells the others. Game-side feature modules never import each
/// other; they talk only through these events (PLAN.md §1.5 rule 2).
public protocol EngineEvent: Sendable {}

/// A registration that can be cancelled. Dropping it does not cancel it.
@MainActor
public final class EventSubscription {
    private var cancelAction: (() -> Void)?

    init(cancel: @escaping () -> Void) {
        cancelAction = cancel
    }

    public func cancel() {
        cancelAction?()
        cancelAction = nil
    }
}

/// Delivers events on the main thread, in subscription order.
@MainActor
public final class EventBus {
    private final class Handler {
        var active = true
        let deliver: (any EngineEvent) -> Void

        init(deliver: @escaping (any EngineEvent) -> Void) {
            self.deliver = deliver
        }
    }

    private var handlers: [ObjectIdentifier: [Handler]] = [:]
    private var pendingEvents: [() -> Void] = []
    private var publishing = false

    public init() {}

    @discardableResult
    public func subscribe<Event: EngineEvent>(
        _ type: Event.Type,
        _ handler: @escaping @MainActor (Event) -> Void
    ) -> EventSubscription {
        let key = ObjectIdentifier(type)
        let entry = Handler { event in
            if let event = event as? Event {
                handler(event)
            }
        }
        handlers[key, default: []].append(entry)
        return EventSubscription { [weak self, weak entry] in
            guard let entry else { return }
            // Snapshots share this liveness bit, so cancellation still takes
            // effect before a later handler's turn without rescanning the list.
            entry.active = false
            self?.handlers[key]?.removeAll { $0 === entry }
        }
    }

    public func publish<Event: EngineEvent>(_ event: Event) {
        let key = ObjectIdentifier(Event.self)
        // Per-frame and per-input events often have no listener: nothing to deliver or order.
        guard let snapshot = handlers[key], !snapshot.isEmpty else { return }
        // Finish the current event before delivering events published by its handlers.
        // Otherwise a settings update can reach later modules before its older update.
        if publishing {
            pendingEvents.append { [self] in deliver(snapshot, event: event) }
            return
        }
        publishing = true
        defer { pendingEvents.removeAll(keepingCapacity: true); publishing = false }
        // The common frame/input event needs no escaping queue closure. Only
        // events actually published from another delivery need to be deferred.
        deliver(snapshot, event: event)
        var index = 0
        while index < pendingEvents.count {
            let deliver = pendingEvents[index]
            index += 1
            deliver()
        }
    }

    private func deliver(_ snapshot: [Handler], event: any EngineEvent) {
        for handler in snapshot where handler.active {
            handler.deliver(event)
        }
    }

    /// Number of handlers for an event type (for tests and diagnostics).
    public func subscriberCount<Event: EngineEvent>(for type: Event.Type) -> Int {
        handlers[ObjectIdentifier(type)]?.count ?? 0
    }
}
