import Foundation
import MulgEngineHooks
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// The iOS app states the game window maps onto: focused is active, on screen but not focused
/// is inactive, minimised or hidden is the background.
public enum LifecycleState: Int, Sendable {
    case background, inactive, active

    /// An iOS transition between two neighbouring states.
    public enum Step: Sendable, Equatable {
        case resignActive, enterBackground, enterForeground, becomeActive
    }

    public init(focused: Bool, onScreen: Bool) {
        self = onScreen ? (focused ? .active : .inactive) : .background
    }

    /// Unfocused, Mulg never brings the game forward from a deeper state: UIKit backgrounded it (another
    /// Space, Mission Control) and brings it back itself. A delayed "inactive" target used to send a game
    /// UIKit still held in the background a fake willEnterForeground; Unity games could then stay paused.
    public static func unfocusedTarget(_ target: LifecycleState, current: LifecycleState) -> LifecycleState {
        target != .active && current.rawValue < target.rawValue ? current : target
    }

    /// The transitions from this state to `target`, in the order iOS sends them. Empty when
    /// the game is already there, so nothing is ever sent twice.
    public func steps(to target: LifecycleState) -> [Step] {
        switch (self, target) {
        case (.active, .inactive): [.resignActive]
        case (.active, .background): [.resignActive, .enterBackground]
        case (.inactive, .background): [.enterBackground]
        case (.inactive, .active): [.becomeActive]
        case (.background, .inactive): [.enterForeground]
        case (.background, .active): [.enterForeground, .becomeActive]
        default: []
        }
    }
}

#if canImport(UIKit) && !os(watchOS)
/// Keeps the game's iOS lifecycle in step with its Mac window: focus, minimising, hiding the
/// game and bringing it back.
///
/// UIKit sends some of these transitions on the Mac itself, but not always all of them, so a
/// game that paused on resign active could stay paused. Whoever sends them, UIKit or Mulg, the
/// native application notifications say where the game is. After a window change, and a
/// moment for UIKit to go first, only the missing steps are sent to game callbacks. Fallback
/// notifications never go through NotificationCenter: Apple observers must see only native
/// transitions, or UIKitMacHelper can assert on a later foreground transition.
@MainActor
public final class GameLifecycle {
    /// Time given to UIKit's own transition before the missing steps are sent.
    static let settleDelay: Duration = .milliseconds(300)

    public private(set) var state = LifecycleState.active
    private var pending: Task<Void, Never>?
    private var ended = false
    private var moving = false
    private var queuedTarget: LifecycleState?
    private var keepRunningUnfocused: Bool
    private var lastWindowFocus = (focused: true, onScreen: true)
    private var sceneStates: [ObjectIdentifier: LifecycleState] = [:]
    private weak var gameScene: UIWindowScene?
    nonisolated private static let syntheticKey = "MulgSyntheticLifecycle"

    /// Starts at active: the runtime creates it once the first scene is active.
    public init(keepRunningUnfocused: Bool = false) {
        self.keepRunningUnfocused = keepRunningUnfocused
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        gameScene = scenes.first(where: { $0.windows.contains(where: \.isKeyWindow) })
            ?? scenes.first(where: { $0.activationState == .foregroundActive })
        for scene in scenes { sceneStates[ObjectIdentifier(scene)] = Self.state(of: scene) }
        let known: [(Notification.Name, LifecycleState)] = [
            (UIApplication.willResignActiveNotification, .inactive),
            (UIApplication.didEnterBackgroundNotification, .background),
            (UIApplication.willEnterForegroundNotification, .inactive),
            (UIApplication.didBecomeActiveNotification, .active)
        ]
        for (name, state) in known {
            _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let synthetic = note.userInfo?[Self.syntheticKey] as? Bool == true
                MainActor.assumeIsolated {
                    self?.state = state
                    if !synthetic {
                        mulg_engine_clear_lifecycle_state(UIApplication.shared)
                        self?.reassertActiveIfNeeded(after: state)
                    }
                }
            }
        }
        let sceneNotifications: [(Notification.Name, LifecycleState)] = [
            (UIScene.willDeactivateNotification, .inactive), (UIScene.didEnterBackgroundNotification, .background),
            (UIScene.willEnterForegroundNotification, .inactive), (UIScene.didActivateNotification, .active)
        ]
        for (name, state) in sceneNotifications {
            _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let synthetic = notification.userInfo?[Self.syntheticKey] as? Bool == true
                nonisolated(unsafe) let object = notification.object
                MainActor.assumeIsolated {
                    guard let scene = object as? UIScene else { return }
                    self?.sceneStates[ObjectIdentifier(scene)] = state
                    if !synthetic {
                        mulg_engine_clear_lifecycle_state(scene)
                        self?.reassertActiveIfNeeded(after: state)
                    }
                }
            }
        }
    }

    /// The game window's focus or visibility may have changed. Quick changes (a click through
    /// another app) are coalesced, so the game is not paused and resumed for nothing.
    public func windowChanged(focused: Bool, onScreen: Bool) {
        lastWindowFocus = (focused, onScreen)
        let target = keepRunningUnfocused ? LifecycleState.active : LifecycleState(focused: focused, onScreen: onScreen)
        let delay = keepRunningUnfocused ? Duration.zero : Self.settleDelay
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.ended else { return }
            self.move(to: target)
        }
    }

    public func setKeepRunningUnfocused(_ enabled: Bool) {
        guard !ended else { return }
        keepRunningUnfocused = enabled
        windowChanged(focused: lastWindowFocus.focused, onScreen: lastWindowFocus.onScreen)
    }

    private func reassertActiveIfNeeded(after nativeState: LifecycleState) {
        guard keepRunningUnfocused, !ended, nativeState != .active else { return }
        windowChanged(focused: lastWindowFocus.focused, onScreen: lastWindowFocus.onScreen)
    }

    /// Sends the game to the background for good (the window is closing); window changes no
    /// longer move it.
    public func end() {
        guard !ended else { return }
        ended = true
        keepRunningUnfocused = false
        mulg_engine_set_keep_active(false)
        pending?.cancel()
        move(to: .background)
    }

    private func move(to target: LifecycleState) {
        queuedTarget = ended ? .background : target
        guard !moving else { return }
        moving = true
        defer { moving = false }
        while let next = queuedTarget {
            queuedTarget = nil
            performMove(to: next)
        }
    }

    private func performMove(to target: LifecycleState) {
        let application = UIApplication.shared
        defer {
            // A delegate may close the window during a foreground transition.
            // Keep the application override in step with the state we reached.
            if ended { mulg_engine_set_lifecycle_state(application, 2 - state.rawValue) }
        }
        let scenes = application.connectedScenes.compactMap { $0 as? UIWindowScene }
        // As on iOS: scene games get the scene delegate calls, and only games without scenes get
        // the app delegate's. The application notifications are posted for both.
        let usesScenes = scenes.contains { $0.delegate != nil }
        let liveScenes = Set(scenes.map(ObjectIdentifier.init))
        sceneStates = sceneStates.filter { liveScenes.contains($0.key) }
        let attached = scenes.filter { $0.activationState != .unattached }
        gameScene = attached.first(where: { $0.windows.contains(where: \.isKeyWindow) })
            ?? attached.first(where: { $0 === GameViewport.shared.window?.windowScene })
            ?? attached.first(where: { Self.state(of: $0) != .background }) ?? attached.first
        let transitions = attached.map { scene -> (UIWindowScene, LifecycleState) in
            // Other foreground windows keep their own focus and visibility.
            let native = Self.state(of: scene)
            let current = sceneStates[ObjectIdentifier(scene)] ?? native
            return (scene, ended || target == .background ? .background
                : (scene === gameScene ? LifecycleState.unfocusedTarget(target, current: current) : (native == .active ? .inactive : native)))
        }
        // No attached scene (none yet, or all briefly unattached) gives no scene states to follow: the same rule as a
        // game without scenes. Folding the empty list gave "background" and sent a focused game to the background.
        let applicationTarget = attached.isEmpty ? LifecycleState.unfocusedTarget(target, current: state) : transitions.reduce(LifecycleState.background) {
            $0.rawValue > $1.1.rawValue ? $0 : $1.1
        }
        let applicationSteps = state.steps(to: applicationTarget)
        for (scene, sceneTarget) in transitions {
            let identity = ObjectIdentifier(scene)
            for step in (sceneStates[identity] ?? Self.state(of: scene)).steps(to: sceneTarget) {
                guard !ended || target == .background else { return }
                mulg_engine_set_lifecycle_state(scene, 2 - step.resultingState.rawValue)
                if applicationSteps.contains(step) {
                    // Scene delegates may query both states before the application notification.
                    mulg_engine_set_lifecycle_state(application, 2 - step.resultingState.rawValue)
                }
                mulg_engine_call_game_lifecycle_delegate(scene.delegate, step.sceneSelector, scene)
                sceneStates[identity] = step.resultingState
                guard !ended || target == .background else { return }
                mulg_engine_notify_game_lifecycle(step.sceneNotification, scene)
            }
        }
        for step in state.steps(to: applicationTarget) {
            guard !ended || target == .background else { return }
            state = step.resultingState
            mulg_engine_set_lifecycle_state(application, 2 - state.rawValue)
            if !usesScenes {
                mulg_engine_call_game_lifecycle_delegate(application.delegate, step.applicationSelector, application)
            }
            guard !ended || target == .background else { return }
            mulg_engine_notify_game_lifecycle(step.applicationNotification, application)
        }
        guard !ended || target == .background else { return }
        state = applicationTarget
    }

    private static func state(of scene: UIScene) -> LifecycleState {
        switch scene.activationState {
        case .foregroundActive: .active
        case .foregroundInactive: .inactive
        default: .background
        }
    }
}

private extension LifecycleState.Step {
    var sceneSelector: Selector {
        let name: String
        switch self {
        case .resignActive: name = "sceneWillResignActive:"
        case .enterBackground: name = "sceneDidEnterBackground:"
        case .enterForeground: name = "sceneWillEnterForeground:"
        case .becomeActive: name = "sceneDidBecomeActive:"
        }
        return NSSelectorFromString(name)
    }

    var applicationSelector: Selector {
        let name: String
        switch self {
        case .resignActive: name = "applicationWillResignActive:"
        case .enterBackground: name = "applicationDidEnterBackground:"
        case .enterForeground: name = "applicationWillEnterForeground:"
        case .becomeActive: name = "applicationDidBecomeActive:"
        }
        return NSSelectorFromString(name)
    }

    var resultingState: LifecycleState {
        switch self {
        case .resignActive, .enterForeground: .inactive
        case .enterBackground: .background
        case .becomeActive: .active
        }
    }
    var sceneNotification: Notification.Name {
        switch self {
        case .resignActive: UIScene.willDeactivateNotification
        case .enterBackground: UIScene.didEnterBackgroundNotification
        case .enterForeground: UIScene.willEnterForegroundNotification
        case .becomeActive: UIScene.didActivateNotification
        }
    }

    var applicationNotification: Notification.Name {
        switch self {
        case .resignActive: UIApplication.willResignActiveNotification
        case .enterBackground: UIApplication.didEnterBackgroundNotification
        case .enterForeground: UIApplication.willEnterForegroundNotification
        case .becomeActive: UIApplication.didBecomeActiveNotification
        }
    }
}
#endif
