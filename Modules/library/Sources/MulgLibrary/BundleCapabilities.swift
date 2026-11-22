#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import Security

/// Original entitlements are captured before rewriting invalidates their signatures.
public struct BundleCapabilities: Sendable {
    public let entitlements: [URL: Data]
    public let unavailable: [String]

    public init(app: URL, binaries: [URL], allowRestricted: Bool = false) throws {
        let plan = SigningPlan(app: app, binaries: binaries, entitlements: app)
        var captured: [URL: Data] = [:]
        var unavailable: [String] = []
        for item in [plan.app] + plan.stages.flatMap({ $0 }) where SigningPlan.bundleExtensions.contains(item.pathExtension) {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(item as CFURL, [], &code) == errSecSuccess, let code else { continue }
            var info: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
                  let values = (info as? [String: Any])?[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { continue }
            let restricted = values.keys.filter(Self.requiresProvisioning)
            unavailable += restricted.map { item.lastPathComponent + ": " + $0 }
            // Nested bundles carry their own entitlements too: the same allow-list applies to every item.
            let supported = values.filter { Self.mayKeep($0.key, value: $0.value, allowRestricted: allowRestricted) }
            captured[item] = try PropertyListSerialization.data(fromPropertyList: supported, format: .xml, options: 0)
        }
        self.entitlements = captured
        self.unavailable = unavailable.sorted()
    }

    static let appSandbox = "com.apple.security.app-sandbox"

    /// Ordinary sandbox permissions a game or one of its extensions (a widget) may keep: network, devices
    /// and the personal data macOS itself asks the player about. Nothing here widens file access.
    public static let sandboxPermissions: Set<String> = [
        "com.apple.security.network.client", "com.apple.security.network.server",
        "com.apple.security.device.audio-input", "com.apple.security.device.camera", "com.apple.security.device.microphone",
        "com.apple.security.device.bluetooth", "com.apple.security.device.usb", "com.apple.security.print",
        "com.apple.security.personal-information.location", "com.apple.security.personal-information.addressbook",
        "com.apple.security.personal-information.calendars", "com.apple.security.personal-information.photos-library",
    ]

    /// Every other macOS sandbox key (temporary exceptions, file access beyond the container, bookmarks,
    /// Apple Events, inherited sandboxes, code-signing relaxations) and debugging rights. An iOS game never
    /// needs one; an IPA that declares them is trying to leave its sandbox.
    public static func isSandboxEscape(_ key: String) -> Bool {
        (key.hasPrefix("com.apple.security.") && !sandboxPermissions.contains(key) && key != appSandbox)
            || key == "get-task-allow" || key == "task_for_pid-allow"
            || key == "run-unsigned-code" || key == "dynamic-codesigning"
    }

    /// Whether a game's own entitlement may reach its new signature: an allow-list (2026-10-10). Ordinary
    /// permissions and keys outside Apple's namespace pass; the sandbox may only be switched on; escapes
    /// never pass. The host's explicit restricted mode also keeps provisioning keys, never Apple-private ones
    /// (with AMFI switched off, as that mode requires, macOS would honour a private key an IPA declares).
    public static func mayKeep(_ key: String, value: Any? = nil, allowRestricted: Bool = false) -> Bool {
        // The sandbox may only ever be switched on.
        if key == appSandbox { return value as? Bool == true }
        if sandboxPermissions.contains(key) { return true }
        if isSandboxEscape(key) { return false }
        if key.hasPrefix("com.apple.private.") || key == "platform-application" { return false }
        if allowRestricted { return true }
        return !requiresProvisioning(key) && !key.hasPrefix("com.apple.")
    }

    public static func requiresProvisioning(_ key: String) -> Bool {
        key == "application-identifier" || key == "com.apple.application-identifier" || key == "platform-application"
            || key == "keychain-access-groups" || key == "aps-environment"
            || key == "com.apple.developer.aps-environment"
            || key.hasPrefix("com.apple.developer.") || key.hasPrefix("com.apple.private.")
            || key == "com.apple.security.application-groups"
    }
}
#endif
