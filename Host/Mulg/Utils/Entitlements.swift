//
//  Entitlements.swift
//  Mulg
//

import Foundation
import MulgContracts
import MulgLibrary
import Security
@preconcurrency import Yams

class Entitlements {
    // These are so critical they MUST be gone no matter what.
    static let critical = [
        "/bin/bash",
        "/usr/sbin/sshd",
        "/usr/libexec/ssh-keysign",
        "/bin/sh",
        "/etc/ssh/sshd_config",
        "/usr/libexec/sftp-server",
        "/usr/bin/ssh"
    ]

    static var mulgEntitlementsDir: URL {
        let entFolder = GameRuntime.mulgContainer.appendingPathComponent("Entitlements")
        if !FileManager.default.fileExists(atPath: entFolder.path) {
            do {
                try FileManager.default.createDirectory(at: entFolder,
                                                        withIntermediateDirectories: true,
                                                        attributes: [:])
            } catch {
                Log.shared.error(error)
            }
        }
        return entFolder
    }

    /// The signature's details, read in-process by Security instead of by running codesign (it
    /// gives the same entitlements and Info.plist binding). nil for code that is not signed at all.
    static func signingInformation(exec: URL) -> [String: Any]? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(exec as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any],
              information[kSecCodeInfoIdentifier as String] != nil else { return nil }
        return information
    }

    /// Mulg signs every game ad hoc, and must: macOS opens a game's sandbox container only for the
    /// kind of signature that created it, so a game later signed with a certificate (build 881
    /// used a local one) dies at launch with "failed integrity checks for container".
    static func isCertificateSigned(exec: URL) -> Bool {
        (signingInformation(exec: exec)?[kSecCodeInfoCertificates as String] as? [Any])?.isEmpty == false
    }

    /// Whether the signature's designated requirement names the bundle identifier (StableSigning)
    /// rather than the exact code hash, so macOS keeps the player's permission answers across
    /// re-signs. Unknown counts as stable: never re-sign on a guess.
    static func hasStableRequirement(exec: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(exec as CFURL, [], &code) == errSecSuccess, let code else { return true }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement else { return true }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return true }
        return !(text as String).contains("cdhash")
    }

    /// Re-signs a game ad hoc, keeping its entitlements: a certificate-signed one so its container
    /// opens again, and an older ad hoc one (requirement = its code hash) once, so macOS stops
    /// asking for its permissions after every Mulg update. Nothing for a game already signed so.
    static func repairSigning(exec: URL) throws {
        let name = exec.deletingLastPathComponent().lastPathComponent
        if isCertificateSigned(exec: exec) {
            Log.shared.log("Re-signing \(name) ad hoc for its container")
        } else if !hasStableRequirement(exec: exec) {
            Log.shared.log("Re-signing \(name) with a stable requirement, so macOS asks for its permissions once")
        } else {
            return
        }
        try Shell.signApp(exec)
    }

    /// The signed entitlements; the template when the code is unsigned or signed without any.
    static func dumpEntitlements(exec: URL) throws -> [String: Any] {
        if let signed = signingInformation(exec: exec)?[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
            return signed
        }
        return try [String: Any].read(Entitlements.entitlements_template) ?? [:]
    }

    static func areEntitlementsValid(app: MulgGame) throws -> Bool {
        guard let old = try dumpEntitlements(exec: app.executable) as? [String: AnyHashable] else { return false }
        guard let new = try composeEntitlements(app) as? [String: AnyHashable] else { return false }
        // Equal hashes do not prove equal contents; a collision would skip a needed re-sign.
        return new == old
    }

    /// What every game gets. No raw access to the player's folders (2026-10-10): Downloads, Movies, Music and
    /// Pictures were read-write for every game. An iOS game reaches photos through the Photos library (macOS
    /// asks the player) and other files through the document picker (only what the player picks).
    private static func setBaseEntitlements(_ base: inout [String: Any]) {
        base["com.apple.security.device.audio-input"] = true
        base["com.apple.security.network.client"] = true
        base["com.apple.security.network.server"] = true
        base["com.apple.security.device.bluetooth"] = true
        base["com.apple.security.device.camera"] = true
        base["com.apple.security.device.microphone"] = true
        base["com.apple.security.device.usb"] = true
        base["com.apple.security.files.user-selected.read-write"] = true
        base["com.apple.security.personal-information.photos-library"] = true
        base["com.apple.security.personal-information.addressbook"] = true
        base["com.apple.security.personal-information.calendars"] = true
        base["com.apple.security.personal-information.location"] = true
        base["com.apple.security.print"] = true
        base["com.apple.security.app-sandbox"] = true
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func composeEntitlements(_ app: MulgGame, dataRoot: URL? = nil) throws -> [String: Any] {
        var base = [String: Any]()
        let bundleID = app.info.bundleIdentifier

        setBaseEntitlements(&base)

        // An allow-list: a game keeps only keys outside Apple's namespace, which grant nothing. Sandbox
        // exceptions, file access and debugging rights an IPA declares are dropped (a malicious IPA could
        // otherwise grant itself access to every file); provisioned cloud services are never claimed.
        let original = try [String: Any].read(app.entitlements) ?? [:]
        for (key, value) in original where base[key] == nil && BundleCapabilities.mayKeep(key, value: value) {
            base[key] = value
        }

        if SystemConfig.isMulgSignActive {
            base["com.apple.private.tcc.allow"] = TCC.split(whereSeparator: \.isNewline)
            // Provisioning keys pass in this explicit mode; sandbox escapes and Apple-private keys still never do.
            for (key, value) in original where BundleCapabilities.mayKeep(key, value: value, allowRestricted: true) {
                base[key] = value
            }
        }

        var sandboxProfile = [String]()

        var rules = try getDefaultRules()
        if let bundleRules = try getBundleRules(bundleID) {
            if !(bundleRules.allow?.isEmpty ?? true) {
                rules.allow = bundleRules.allow
            }
            if !(bundleRules.bypass?.isEmpty ?? true) {
                rules.bypass = bundleRules.bypass
            }
        }

        // The game may write its own settings file, so the choices that widen its sandbox come from the app's
        // own record of what the player chose (SandboxPolicy), never from that file.
        let policy = SandboxPolicy.load(for: bundleID)
        if policy.discordActivity {
             rules.allow?.append("(allow network* ipc-posix*)")
         }

        sandboxProfile.append(contentsOf: MulgRules.buildRules(rules: rules.allow ?? [], bundleID: bundleID))
        let storage = try dataRoot ?? GameDataStorage.root(for: app.url, bundleIdentifier: bundleID)
        sandboxProfile.append(contentsOf: GameDataStorage.sandboxRules(for: storage))
        sandboxProfile.append("(deny process-fork)")
        for file in critical {
            sandboxProfile.append("""
                    (deny file* file-read* file-read-metadata file-ioctl (literal "\(file)"))
                    """)
        }

        if policy.bypass {
            for file in MulgRules.buildRules(rules: rules.blocklist ?? [], bundleID: bundleID) {
                sandboxProfile.append(
                    """
                     (deny file* file-read* file-read-metadata file-ioctl (literal "\(file)"))
                    """)
            }

            for file in MulgRules.buildRules(rules: rules.greenlist ?? [], bundleID: bundleID) {
                sandboxProfile.append(
                    """
                     (allow file* file-read* file-read-metadata file-ioctl (literal "\(file)"))
                    """)
            }

            // Older bundled/user profiles denied every file operation. A later app-subpath
            // exception does not cover all native bundle/volume discovery operations.
            // Keep explicit path denials, including jailbreak paths, and native sandbox policy.
            let compatibility = MulgRules.buildRules(rules: rules.bypass ?? [], bundleID: bundleID)
            sandboxProfile.append(contentsOf: SandboxCompatibilityRules.preservingNativeFileAccess(compatibility))
        }

        // Keep the installed bundle and owned storage reachable even under legacy
        // compatibility's blanket file restriction. Canonical paths include NAS/USB apps.
        sandboxProfile.append(contentsOf: GameBundleReadAccess.sandboxRules(for: app.url))
        // Its own files in Mulg's folder and its own app groups, not every game's data or every app's groups.
        GameSandboxAccess.prepareFolders(for: bundleID)
        sandboxProfile.append(contentsOf: GameSandboxAccess.sandboxRules(for: bundleID) ?? [])
        let groups = original["com.apple.security.application-groups"] as? [String] ?? []
        sandboxProfile.append(contentsOf: GameSandboxAccess.groupContainerRules(groups: groups, home: ContainerPaths.realHomeDirectory()))
        sandboxProfile.append(contentsOf: GameDataStorage.sandboxRules(for: storage))
        // The keychain wall, last: the game can never reach the macOS Keychain, whatever code it runs. Only the
        // one launch that moves an older Keychain-held login key into its sealed file runs without it.
        if !GameSandboxAccess.keychainMigrationLaunch(for: bundleID, savesLogins: app.settings.settings.mulgChain,
                                                      legacyKeyExists: legacyCredentialKeyExists) {
            sandboxProfile.append(contentsOf: GameSandboxAccess.keychainWallRules(home: ContainerPaths.realHomeDirectory()))
        }
        base["com.apple.security.temporary-exception.sbpl"] = sandboxProfile
        // Last, so nothing above can switch it off.
        base["com.apple.security.app-sandbox"] = true

        return base
    }

    /// Whether the login keychain still holds the database key an older Mulg kept there for this game: the
    /// one reason to open the migration window. Attributes only, so macOS asks nothing and no secret is read.
    static func legacyCredentialKeyExists(_ bundleIdentifier: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.mulg.credentials.v1",
            kSecAttrAccount as String: bundleIdentifier + ".db",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: false,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// What the explicit MulgSign mode answers for the player without a prompt: devices and personal data an
    /// iOS game asks for. Never control of other apps (Apple Events, Accessibility, posting events) or file
    /// access beyond the sandbox (full disk, documents): those let one game act outside itself.
    private static let TCC =
        """
        kTCCServiceAddressBook
        kTCCServiceCalendar
        kTCCServiceReminders
        kTCCServicePhotos
        kTCCServicePhotosAdd
        kTCCServiceMicrophone
        kTCCServiceCamera
        kTCCServiceMediaLibrary
        kTCCServiceLocation
        """

    public static func getDefaultRules() throws -> MulgRules {
        var path: URL
        let yamlURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("Mulg")
            .appendingPathComponent("default")
            .appendingPathExtension("yaml")
        if FileManager.default.fileExists(atPath: yamlURL.path) {
            path = yamlURL
        } else if let bpath = Bundle.main.path(forResource: "default", ofType: "yaml") {
            path = URL(fileURLWithPath: bpath)
        } else {
            throw "Default config not found: default.yaml"
        }

        do {
            let data = try Data(contentsOf: path, options: .mappedIfSafe)
            let decoder = YAMLDecoder()
            let decoded: MulgRules = try decoder.decode(MulgRules.self, from: data)
            return decoded
        } catch {
            print("failed to get default rules at \(path): \(error)")
            throw "failed to get default rules at \(path): \(error)"
        }
    }

    public static func getBundleRules(_ bundleID: String) throws -> MulgRules? {
        var path: URL
        let yamlURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("Mulg")
            .appendingPathComponent(bundleID)
            .appendingPathExtension("yaml")
        if FileManager.default.fileExists(atPath: yamlURL.path) {
            path = yamlURL
        } else if let bpath = Bundle.main.path(forResource: bundleID, ofType: "yaml") {
            path = URL(fileURLWithPath: bpath)
        } else {
            return nil
        }

        do {
            let data = try Data(contentsOf: path, options: .mappedIfSafe)
            let decoder = YAMLDecoder()
            let decoded: MulgRules = try decoder.decode(MulgRules.self, from: data)
            return decoded
        } catch {
            print("failed to get bundle rules at \(path): \(error)")
            throw error
        }
    }

    static let entitlements_template = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        </dict>
        </plist>
        """
}

public func == <K, L: Hashable, R: Hashable>(lhs: [K: L], rhs: [K: R]) -> Bool {
    (lhs as NSDictionary).isEqual(to: rhs)
}

extension Dictionary {
    func store(_ toUrl: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: self, format: .xml, options: 0)
        try data.write(to: toUrl, options: .atomic)
    }

    static func read(_ from: URL) throws -> Dictionary? {
        var format = PropertyListSerialization.PropertyListFormat.xml
        if let data = FileManager.default.contents(atPath: from.path) {
            return try PropertyListSerialization.propertyList(
                from: data,
                options: .mutableContainersAndLeaves,
                format: &format) as? Dictionary
        }
        return nil
    }

    static func read(_ from: String) throws -> Dictionary? {
        var format = PropertyListSerialization.PropertyListFormat.xml
        if let data = from.data(using: .utf8) {
            return try PropertyListSerialization.propertyList(
                from: data,
                options: .mutableContainersAndLeaves,
                format: &format) as? Dictionary
        }
        return nil
    }
}
