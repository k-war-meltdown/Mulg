import Foundation
import Darwin
import MulgContracts
import MulgEngineHooks
import os

/// Bounded wait for declared iOS background work. A quiet process is not proof of cloud sync.
public enum ShutdownPolicy {
    public static func shouldTerminate(elapsed: Double, backgroundTasks: Int, settings: EngineSettings,
                                       trackingAvailable: Bool = true) -> Bool {
        elapsed >= settings.shutdownDeadline || (trackingAvailable && elapsed >= settings.shutdownGrace && backgroundTasks == 0)
    }
}

#if canImport(UIKit) && !os(watchOS)
import UIKit

/// Closing the game window quits the game the way iOS ends an app: resign active, enter the
/// background, disconnect scenes, then terminate (upstream `quitWhenClose`).
///
/// Changes from upstream:
/// - cloud-connected games get a configurable grace period, then may finish declared iOS
///   background tasks until a hard deadline. Neither silence nor task completion confirms
///   a real game's server accepted progress;
/// - it runs once even if the window sends its close notification twice;
/// - a game already inactive or in the background (a window closed while not focused) does not
///   get those transitions again (`GameLifecycle`);
/// - `applicationWillTerminate` is still called on the delegate but its notification is not
///   posted, as upstream found some games freeze on it.
@MainActor
public enum GameShutdown {
    private static var running = false
    private static var watchdog: ShutdownWatchdog?

    /// Time the orderly end (scene disconnect, applicationWillTerminate:, native termination) gets after the
    /// shutdown deadline before the watchdog forces the exit. The watchdog used to fire at the deadline
    /// itself, the same moment `run` stops waiting for background tasks: a game that kept a task open to
    /// the end was killed before applicationWillTerminate:, and its quit counted as an unfinished launch
    /// (two of those and the next launch started in safe mode).
    static let terminationMargin: Double = 5

    /// Ends the process at the shutdown deadline (plus `terminationMargin`) unless it ended first. Armed by
    /// `run`, and by a quit UIKit deferred, which nothing else would ever force. Only the first call arms it.
    public static func armDeadline(settings: EngineSettings, logger: Logger,
                                   onDeadline: @escaping @Sendable () -> Void = {}) {
        guard watchdog == nil else { return }
        watchdog = ShutdownWatchdog(deadline: settings.shutdownDeadline + terminationMargin) {
            logger.error("Forced shutdown deadline; callbacks or native termination did not finish. Cloud sync is not confirmed")
            onDeadline()
            _exit(75)
        }
    }

    public static func run(lifecycle: GameLifecycle, settings: EngineSettings, logger: Logger,
                           onDeadline: @escaping @Sendable () -> Void = {},
                           terminate: @escaping @MainActor () -> Void) {
        guard !running else { return }
        running = true

        let clock = ContinuousClock()
        let start = clock.now
        armDeadline(settings: settings, logger: logger, onDeadline: onDeadline)
        // 1. Resign active, 2. enter the background: games may finish cloud work here.
        lifecycle.end()

        Task { @MainActor in
            var tasks = 0
            while true {
                let duration = start.duration(to: clock.now).components
                let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
                tasks = Int(mulg_engine_background_task_count())
                if ShutdownPolicy.shouldTerminate(elapsed: elapsed, backgroundTasks: tasks, settings: settings,
                                                   trackingAvailable: mulg_engine_background_tracking_available()) { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if !mulg_engine_background_tracking_available() {
                logger.warning("Shutdown deadline reached; background-task tracking is unavailable. Cloud sync is not confirmed")
            } else if tasks > 0 {
                logger.warning("Shutdown deadline reached with \(tasks) background tasks; cloud sync is not confirmed")
            } else {
                logger.info("Shutdown grace finished; no declared background tasks remain. Cloud sync is not confirmed")
            }
            // 3. Disconnect and terminate.
            let application = UIApplication.shared
            for scene in application.connectedScenes {
                mulg_engine_call_game_lifecycle_delegate(scene.delegate, NSSelectorFromString("sceneDidDisconnect:"), scene)
                mulg_engine_notify_game_lifecycle(UIScene.didDisconnectNotification, scene)
            }
            mulg_engine_call_game_lifecycle_delegate(application.delegate, NSSelectorFromString("applicationWillTerminate:"), application)
            terminate()
        }
    }
}
#endif
