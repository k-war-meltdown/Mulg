import Foundation
import MulgGraphicsHooks

/// A scene adapter must use the renderer's own API and be able to undo its request.
/// Capability discovery is read-only; stripped engines require an exact verified binary ABI.
@MainActor
protocol NativeSceneResolutionAdapter: AnyObject {
    func probe() -> MulgNativeSceneState
    func apply(_ enabled: Bool) -> MulgNativeSceneState
    var ownsEngineValues: Bool { get }
    var diagnostics: [String: Any] { get }
}

@MainActor
final class UnityNativeSceneResolutionAdapter: NativeSceneResolutionAdapter {
    func probe() -> MulgNativeSceneState { mulg_native_scene_probe() }
    func apply(_ enabled: Bool) -> MulgNativeSceneState { mulg_native_scene_update(enabled) }
    var ownsEngineValues: Bool { mulg_native_scene_owns_values() }
    var diagnostics: [String: Any] { mulg_native_scene_report() }
}

@MainActor
final class PostProcessNativeSceneResolutionAdapter: NativeSceneResolutionAdapter {
    func probe() -> MulgNativeSceneState { mulg_post_process_scene_probe() }
    func apply(_ enabled: Bool) -> MulgNativeSceneState { mulg_post_process_scene_update(enabled) }
    var ownsEngineValues: Bool { mulg_post_process_scene_owns_values() }
    var diagnostics: [String: Any] { mulg_post_process_scene_report() }
}

@MainActor
final class MobilePresetNativeSceneResolutionAdapter: NativeSceneResolutionAdapter {
    func probe() -> MulgNativeSceneState { mulg_mobile_preset_scene_probe() }
    func apply(_ enabled: Bool) -> MulgNativeSceneState { mulg_mobile_preset_scene_update(enabled) }
    var ownsEngineValues: Bool { mulg_mobile_preset_scene_owns_values() }
    var diagnostics: [String: Any] { mulg_mobile_preset_scene_report() }
}

/// Owns exactly one verified engine adapter at a time. Refusing an unsupported engine leaves
/// the existing output/legacy settings alone. An active trial must restore before it can hand
/// ownership back, even if a user turns the setting off or enables MetalFX in the meantime.
@MainActor
final class NativeSceneResolution {
    private let adapters: [any NativeSceneResolutionAdapter]
    private var active: (any NativeSceneResolutionAdapter)?
    private var observed: (any NativeSceneResolutionAdapter)?
    private var restorationAttempts = 0
    private var status = "off"
    private var enabled = false

    init(adapters: [any NativeSceneResolutionAdapter] = [
        UnityNativeSceneResolutionAdapter(), PostProcessNativeSceneResolutionAdapter(),
        MobilePresetNativeSceneResolutionAdapter(),
    ]) {
        self.adapters = adapters
    }

    var managesScene: Bool { active != nil }
    var hasRequest: Bool { enabled || managesScene }
    var needsRestoreRetry: Bool { active?.ownsEngineValues == true && restorationAttempts < 3 }
    var waitingForEngine: Bool { status == "waitingForEngine" || status == "presetStaged" }

    func reconcile(requested: Bool, outputForced: Bool, metalFXActive: Bool, releaseLegacy: () -> Void) {
        enabled = requested
        let eligible = requested && outputForced && !metalFXActive
        if !eligible || restorationAttempts > 0 {
            if let active {
                if restorationAttempts < 3 {
                    restorationAttempts += 1
                    _ = active.apply(false)
                }
                guard !active.ownsEngineValues else {
                    status = restorationAttempts < 3 ? "restorationPending" : "restartToRestore"
                    return
                }
                self.active = nil
            }
            restorationAttempts = 0
            if !eligible {
                status = !requested ? "off" : metalFXActive ? "metalFXActive" : "requiresForcedOutput"
                return
            }
        }
        restorationAttempts = 0
        if active == nil {
            var discovery = "unsupported"
            observed = adapters.first
            for adapter in adapters {
                switch adapter.probe() {
                case .ready:
                    releaseLegacy()
                    active = adapter
                    observed = adapter
                case .waiting where discovery != "waitingForEngine":
                    discovery = "waitingForEngine"
                    observed = adapter
                case .failed where discovery == "unsupported":
                    discovery = "engineQueryFailed"
                    observed = adapter
                default: break
                }
                if active != nil { break }
            }
            guard active != nil else { status = discovery; return }
        }
        switch active?.apply(true) {
        case .applied: status = "engineAccepted"
        case .waiting: status = "waitingForEngine"
        case .presetStaged: status = "presetStaged"
        case .overridden: status = "gameOverrides"
        case .unsupported:
            status = "unsupported"
            if active?.ownsEngineValues == false { active = nil }
        default: status = "engineRequestFailed"
        }
    }

    var report: [String: Any] {
        var values: [String: Any] = ["enabled": enabled, "status": status, "nativeSceneVerified": false]
        if let observed {
            let diagnostics = observed.diagnostics
            if enabled || managesScene {
                values["engine"] = diagnostics
            } else if let rollback = diagnostics["directPresetRollbackResult"] as? String {
                values["lastPresetRollback"] = rollback
            }
        }
        return values
    }
}
