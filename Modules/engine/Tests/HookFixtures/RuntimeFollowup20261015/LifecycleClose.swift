import Foundation
// __STATE__
enum Activation { case foregroundActive, foregroundInactive, background, unattached }
@MainActor class UIScene: NSObject {
    var activationState = Activation.background
    var delegate: NSObject? = NSObject()
    nonisolated static let willDeactivateNotification = Notification.Name("scene.resign"), didEnterBackgroundNotification = Notification.Name("scene.background")
    nonisolated static let willEnterForegroundNotification = Notification.Name("scene.foreground"), didActivateNotification = Notification.Name("scene.active")
}
@MainActor final class Window { var isKeyWindow = true; weak var windowScene: UIWindowScene? }
@MainActor final class UIWindowScene: UIScene { var windows: [Window] = [] }
@MainActor final class UIApplication {
    static let shared = UIApplication()
    var connectedScenes: Set<UIWindowScene> = [], delegate: NSObject? = NSObject()
    nonisolated static let willResignActiveNotification = Notification.Name("app.resign"), didEnterBackgroundNotification = Notification.Name("app.background")
    nonisolated static let willEnterForegroundNotification = Notification.Name("app.foreground"), didBecomeActiveNotification = Notification.Name("app.active")
}
@MainActor enum GameViewport { static let shared = Viewport(); final class Viewport { var window: Window? } }
var events: [String] = [], callback: ((String) -> Void)?, applicationOverride = -1
@MainActor func mulg_engine_set_keep_active(_ enabled: Bool) {}
@MainActor func mulg_engine_set_lifecycle_state(_ object: AnyObject, _ state: Int) {
    if object === UIApplication.shared { applicationOverride = state }
}
@MainActor func mulg_engine_call_game_lifecycle_delegate(_ delegate: NSObject?, _ selector: Selector, _ object: AnyObject) {
    let name = NSStringFromSelector(selector); events.append(name); callback?(name)
}
@MainActor func mulg_engine_notify_game_lifecycle(_ name: Notification.Name, _ object: AnyObject) { events.append(name.rawValue) }
@MainActor final class GameLifecycle {
    var state = LifecycleState.background, ended = false, keepRunningUnfocused = false, moving = false
    var queuedTarget: LifecycleState?, pending: Task<Void, Never>?, sceneStates: [ObjectIdentifier: LifecycleState] = [:]
    weak var gameScene: UIWindowScene?
    func testMove() { move(to: .active) }
    // __PRODUCTION__
}
// __STEPS__
Task { @MainActor in
    for usesScene in [true, false] {
        let lifecycle = GameLifecycle()
        UIApplication.shared.connectedScenes = usesScene ? [UIWindowScene()] : []
        events = []; applicationOverride = -1
        callback = { name in if name.contains("WillEnterForeground") { lifecycle.end() } }
        lifecycle.testMove()
        assert(lifecycle.ended && lifecycle.state == .background && applicationOverride == 2)
        assert(!events.contains(where: { $0.contains("BecomeActive") || $0.hasSuffix(".active") }), "Closing during foreground must not reactivate the game")
    }
    callback = nil; events = []
    let normal = GameLifecycle(); normal.testMove()
    assert(normal.state == .active && events.contains("applicationDidBecomeActive:"))
    print("PASS: closing inside lifecycle callbacks aborts foreground activation and ends in background")
    exit(0)
}
dispatchMain()
