import Foundation

/// One policy for managed launches and the runtime fallback in exported games.
public enum LaunchEnvironment {
    public static let recoveryThreshold = 2
    /// These identify the host process, not its child game. Launch Services supplies
    /// the game's own values. In particular CFProcessPath can override CF's main bundle.
    private static let hostProcessKeys: Set<String> = [
        "CFProcessPath", "__CFBundleIdentifier", "__CFBundleURL",
        "APP_SANDBOX_CONTAINER_ID", "XPC_SERVICE_NAME", "XPC_FLAGS"
    ]
    public static let managedMetalKeys: Set<String> = [
        "METAL_DEVICE_WRAPPER_TYPE", "METAL_DEBUG_LAYER", "MTL_DEBUG_LAYER", "METAL_API_VALIDATION",
        "METAL_SHADER_VALIDATION", "METAL_SHADER_VALIDATION_OPTIONS", "METAL_CAPTURE_ENABLED",
        "METAL_CAPTURE_OUTPUT_FILE", "METAL_CAPTURE_TYPE", "METAL_FORCE_LAZY_COMPILATION",
        "METAL_FRAME_CAPTURE_ENABLED", "METAL_ERROR_MODE", "MTLCaptureEnabled",
        "MTL_HUD_ENABLED", "MTL_HUD_LOG_ENABLED", "MTL_SHADER_VALIDATION",
        "MTL_DEBUG_LAYER_ERROR_MODE", "MTL_DEBUG_LAYER_WARNING_MODE"
    ]

    /// The game's own environment variables. Apple's external Metal tools (performance HUD, API and
    /// shader validation, capture, device wrappers) are never set and are removed even from custom
    /// variables: they inject interposers between the game and Metal, where Mulg's graphics hooks
    /// already sit, and no longer have switches in Mulg. Old settings that turned them on are ignored.
    public static func overrides(_ settings: GameSettings, minimalRecovery: Bool = false) -> [String: String] {
        settings.mulg.engine.environment.filter {
            EngineSettings.environmentProblem(name: $0.key, value: $0.value) == nil && !managedMetalKeys.contains($0.key)
        }
    }

    public static func make(_ settings: GameSettings, inherited: [String: String],
                            minimalRecovery: Bool = false) -> [String: String] {
        inherited.filter { !$0.key.hasPrefix("DYLD_") && !managedMetalKeys.contains($0.key)
            && !hostProcessKeys.contains($0.key) }
            .merging(overrides(settings, minimalRecovery: minimalRecovery)) { _, game in game }
    }

    /// Read before reserving/starting a launch; the runtime increments this same counter.
    public static func needsMinimalRecovery(marker: URL, settings: GameSettings? = nil) -> Bool {
        guard settings?.mulg.engine.automaticRecovery != false else { return false }
        guard let data = try? Data(contentsOf: marker) else { return false }
        struct Counter: Decodable { let unfinishedLaunches: Int; let stage: String? }
        if (try? JSONDecoder().decode(Counter.self, from: data).stage) == "healthy" { return false }
        let count = (try? JSONDecoder().decode(Counter.self, from: data).unfinishedLaunches)
            ?? String(data: data, encoding: .utf8).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        return count >= recoveryThreshold * 2
    }
}
