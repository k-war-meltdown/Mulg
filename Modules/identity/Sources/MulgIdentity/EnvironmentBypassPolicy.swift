import Foundation
import MulgContracts

/// The opt-in compatibility policy lives with identity. Existing platform and SDK hook
/// ownership stays in that module; neither rendering nor input delivery is involved.
struct EnvironmentBypassPolicy {
    let enabled: Bool
    let launchStartedAt = Date()
    let deviceIdentifier: String
    let answersKnownSDKChecks: Bool

    init(settings: GameSettings, legacyEnvironmentRequested: Bool) {
        enabled = settings.mulg.identity.environmentBypass
        deviceIdentifier = settings.iosDeviceModel
        answersKnownSDKChecks = enabled || settings.bypass || legacyEnvironmentRequested
    }
}
