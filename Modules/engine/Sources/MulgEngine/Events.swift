import Foundation
import MulgContracts

// Events shared between game-side modules. They live in the engine because every game-side
// module may depend on the engine, but not on each other (PLAN.md §1.5 rule 2).

/// The game's first scene became active; deferred start-up work may begin (§16.2 E5).
public struct SceneActivated: EngineEvent {
    public init() {}
}

/// The user closed the game window or quit the game: the launch ended cleanly, so it does not
/// count towards safe mode, however short it was.
public struct GameClosing: EngineEvent {
    public init() {}
}

/// The display showing the game changed, or its refresh rate did (§4.1).
public struct DisplayRefreshRateChanged: EngineEvent {
    public let maximumRefreshRate: Int
    public init(maximumRefreshRate: Int) {
        self.maximumRefreshRate = maximumRefreshRate
    }
}

/// The Mac switched between battery and mains power (§13.1).
public struct PowerSourceChanged: EngineEvent {
    public let onBattery: Bool
    public init(onBattery: Bool) {
        self.onBattery = onBattery
    }
}

/// The game's battery saver (`display.batterySaverOnBattery`) started or stopped: the Mac went
/// on or off battery power, or macOS Low Power Mode changed (§7). Only sent when the game has
/// battery saver on.
public struct BatterySaverChanged: EngineEvent {
    public let active: Bool
    public init(active: Bool) {
        self.active = active
    }
}

/// The Mac became seriously hot, or cooled down again (§13.1). Sent once at activation and on
/// every change, whether or not the thermal guard is on. The game itself is told nominal.
public struct MacHeatChanged: EngineEvent {
    public let hot: Bool
    public init(hot: Bool) {
        self.hot = hot
    }
}

/// The fastest the game may present frames changed (§6.1, §13.1): the background throttle
/// while hidden, otherwise the lowest of the frame-rate cap, the battery saver and the thermal
/// guard. 0 means no limit. Sent by `display` at activation and on every change.
public struct FrameLimitChanged: EngineEvent {
    public let framesPerSecond: Int
    /// The display's refresh rate, so the limit can land on refresh boundaries.
    public let refreshRate: Int
    /// The display varies its refresh rate and the window is full screen, so frames can be held
    /// exactly 1/limit instead of whole refreshes (ProMotion, Adaptive-Sync).
    public let variableRefresh: Bool
    public init(framesPerSecond: Int, refreshRate: Int, variableRefresh: Bool = false) {
        self.framesPerSecond = framesPerSecond
        self.refreshRate = refreshRate
        self.variableRefresh = variableRefresh
    }
}

/// This game's settings changed while it runs (§7): in the Mulg app (the settings file was reloaded)
/// or from inside the game (`ModuleContext.updateSettings`, such as an in-game menu toggle).
/// `context.settings` already holds `new` when this is sent. Modules apply what can change live; the
/// rest waits for the next launch.
public struct SettingsChanged: EngineEvent {
    public let old: GameSettings
    public let new: GameSettings
    public init(old: GameSettings, new: GameSettings) {
        self.old = old
        self.new = new
    }
}

/// The game window became hidden, covered or visible again (§13.1).
public struct WindowVisibilityChanged: EngineEvent {
    public let visible: Bool
    public init(visible: Bool) {
        self.visible = visible
    }
}

/// The MetalFX layer was switched on or off, or its preset changed (§5.2).
public struct MetalFXStateChanged: EngineEvent {
    public let enabled: Bool
    public let preset: MetalFXPreset
    public init(enabled: Bool, preset: MetalFXPreset) {
        self.enabled = enabled
        self.preset = preset
    }
}

/// The game created its own MetalFX object; the layer must switch itself off (§5.2.7).
public struct GameUsesOwnMetalFX: EngineEvent {
    public let feature: String
    public init(feature: String) {
        self.feature = feature
    }
}

/// The cursor was shown or hidden by the controls module (hold-Option, menus) (§14.2).
public struct CursorVisibilityChanged: EngineEvent {
    public let visible: Bool
    public init(visible: Bool) {
        self.visible = visible
    }
}

/// An input event reached the game, with the time it arrived (§6.1 measurement).
public struct InputDelivered: EngineEvent {
    /// Mach absolute time when the event arrived from macOS.
    public let arrival: UInt64
    /// Mach absolute time when it was injected into the game.
    public let injected: UInt64
    public init(arrival: UInt64, injected: UInt64) {
        self.arrival = arrival
        self.injected = injected
    }
}

/// A frame was presented, with its presentation time (§6.1 measurement).
public struct FramePresented: EngineEvent {
    /// Seconds, in the same clock as `CACurrentMediaTime()`.
    public let presentedTime: Double
    public init(presentedTime: Double) {
        self.presentedTime = presentedTime
    }
}

/// Every game-side module has been started; carries what happened to each (§8.3). Published
/// once, just before `SceneActivated`.
public struct ModulesStarted: EngineEvent {
    public let reports: [ModuleReport]
    public init(reports: [ModuleReport]) {
        self.reports = reports
    }
}

/// A module needs, or no longer needs, per-frame presentation times (`FramePresented`).
/// Reporting costs a little per frame, so `graphics` only does it while someone asks (§8).
public struct FrameReportingRequested: EngineEvent {
    public let requester: ModuleID
    public let enabled: Bool
    public init(requester: ModuleID, enabled: Bool) {
        self.requester = requester
        self.enabled = enabled
    }
}

/// Published only after bounded shutdown work and termination callbacks finish.
public struct GameShutdownFinished: EngineEvent {
    public init() {}
}

/// Wrapper caches should release idle allocations even when game warnings are disabled.
public struct MemoryPressure: EngineEvent {
    public init() {}
}

/// A short, current summary a module wants in crash and freeze reports (the input mode and held
/// inputs, for one). Replaces that module's previous note; empty text removes it.
public struct DiagnosticNote: EngineEvent {
    public let module: ModuleID
    public let text: String
    public init(module: ModuleID, text: String) {
        self.module = module
        self.text = text
    }
}

/// Cancels camera-requested pinches when calibration or camera reach stops.
public struct CameraZoomCancelled: EngineEvent {
    public init() {}
}

/// The camera module asks for the game's camera to be zoomed all the way in one direction (Camera
/// reach calibration). The controls module performs it as two-finger pinches; nothing happens when
/// controls is off, so the camera module checks for a subscriber first.
public struct CameraZoomRequested: EngineEvent {
    /// Away from the character (pinching in), or towards it.
    public let outward: Bool
    /// Whole pinches; enough to reach the game's limit from anywhere.
    public let gestures: Int
    public init(outward: Bool, gestures: Int) {
        self.outward = outward
        self.gestures = gestures
    }

    /// How long `gestures` pinches take, for the requester to wait (PinchZoom.sweep).
    public static func duration(gestures: Int) -> Duration { .milliseconds(380 * max(1, gestures)) }
}

/// The player zoomed the camera (scroll wheel turned into a pinch by the controls module). Camera
/// reach follows it: it extends past the game's limit only while the player is zooming out.
public struct PlayerZoomed: EngineEvent {
    public let outward: Bool
    public init(outward: Bool) { self.outward = outward }
}
