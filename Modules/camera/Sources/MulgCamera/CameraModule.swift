import Foundation
import MulgContracts
import MulgEngine

/// Camera reach (PLAN.md §16.13): lets the camera zoom out farther than the game allows.
///
/// Per game and off by default (`camera.extendedReach`). Calibration starts only when the player
/// presses the hotkey (Shift+9) in the game world, never by itself (a loading screen or menu would
/// make it fail); it then zooms by itself through the controls module. The limit is found again by
/// value on every launch; a game update that changes it asks for another press. Experimental: safe mode switches it off after repeated crashes.
@MainActor
public final class CameraModule: GameModule {
    public let id = ModuleID.camera
    public var isExperimental: Bool { true }
    private var controller: CameraReachController?
    private var registeredHotkey: Hotkey?
    private var subscriptions: [EventSubscription] = []

    public init() {}

    public func prepare(_ context: ModuleContext) throws {}

    public func activate(_ context: ModuleContext) {
        if CameraCrashGuard.previousSessionCrashed(context) {
            CameraCrashGuard.clear(context)
            if context.settings.mulg.camera.extendedReach, context.updateSettings({ $0.mulg.camera.extendedReach = false }) {
                context.logger(for: id).error("Camera reach switched off: the last session ended while it had changed the game")
                context.notices.show(Notice("Camera reach switched off", lines: [
                    "The game closed unexpectedly last time while camera reach was raising its zoom limit.",
                    "Turn it on again under Performance & FPS → 120 FPS & camera, ideally with a smaller reach."
                ], style: .warning, duration: .seconds(8), important: true))
            }
        }
        let controller = CameraReachController(context: context)
        self.controller = controller
        registerHotkey(context)
        registerMenu(context, controller: controller)
        subscriptions = [
            context.events.subscribe(SettingsChanged.self) { [weak self, weak context] change in
                guard let self, let context else { return }
                let old = change.old.mulg.camera, new = change.new.mulg.camera
                if old.calibrateHotkey != new.calibrateHotkey { self.registerHotkey(context) }
                self.controller?.apply(new)
            },
            context.events.subscribe(MemoryPressure.self) { [weak controller] _ in controller?.memoryPressure() },
            // Hold mode extends only while the player zooms out, and lets go when they zoom in.
            context.events.subscribe(PlayerZoomed.self) { [weak controller] event in
                controller?.playerZoomed(outward: event.outward)
            },
            context.events.subscribe(GameClosing.self) { [weak controller] _ in controller?.stop() }
        ]
        controller.start()
    }

    private func registerHotkey(_ context: ModuleContext) {
        if let registeredHotkey {
            context.hotkeys.unregister(registeredHotkey)
            self.registeredHotkey = nil
        }
        let text = context.settings.mulg.camera.calibrateHotkey
        guard let hotkey = Hotkey(text) else {
            context.logger(for: id).error("Invalid camera reach hotkey '\(text, privacy: .public)'")
            return
        }
        do {
            try context.hotkeys.register(hotkey, owner: id, title: "Calibrate camera reach") { [weak self] in
                self?.controller?.calibrationKeyPressed()
            }
            registeredHotkey = hotkey
        } catch {
            context.logger(for: id).error("Camera reach hotkey \(hotkey.description, privacy: .public) is taken")
        }
    }

    private func registerMenu(_ context: ModuleContext, controller: CameraReachController) {
        let commands: [(String, String, String, @MainActor () -> Void)] = [
            ("camera.calibrate", "Calibrate / Next Step", "camera.viewfinder", { [weak controller] in
                controller?.calibrationKeyPressed()
            }),
            ("camera.cancel", "Cancel Calibration", "xmark.circle", { [weak controller] in
                controller?.cancelCalibration(notice: Notice("Camera reach calibration cancelled"))
            }),
            ("camera.forget", "Forget Calibration", "trash", { [weak controller] in
                controller?.forgetCalibration()
            })
        ]
        for (identifier, title, symbol, action) in commands {
            try? context.menus.register(MenuCommand(id: identifier, title: title, symbol: symbol, key: "",
                                                    section: "camera", submenu: "Camera Reach"),
                                        owner: id, action: action)
        }
    }
}
