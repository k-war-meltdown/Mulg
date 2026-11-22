//
//  AppSettings.swift
//  Mulg
//

import AppKit
import Combine
import Foundation
import MulgContracts
import UniformTypeIdentifiers

struct AppSettingsData: Codable {
    var bundleIdentifier: String = ""

    var keymapping = true
    var sensitivity: Float = 50

    var disableTimeout = false
    var displayRotation = 0
    var iosDeviceModel = "iPad17,3"
    var windowWidth = 1920
    var windowHeight = 1080
    var customScaler = 2.0
    /// Keep legacy host defaults aligned with the shared desktop-resolution policy.
    var resolution = GameSettings().resolution
    var aspectRatio = 1
    var notch: Bool = NSScreen.hasNotch()
    var bypass = false
    var discordActivity = DiscordActivity()
    var version = "3.0.0"
    var mulgChain = true
    var mulgChainDebugging = false
    var inverseScreenValues = false
    /// Kept so old settings files decode; the Metal performance HUD is no longer offered.
    var metalHUD = false
    var windowFixMethod = 0
    var injectIntrospection = false
    var rootWorkDir = true
    var noKMOnInput = true
    var enableScrollWheel = true
    var hideTitleBar = GameSettings().hideTitleBar
    var floatingWindow = false
    var checkMicPermissionSync = false
    var limitMotionUpdateFrequency = false
    var disableBuiltinMouse = false
    var resizableAspectRatioType = 0
    var resizableAspectRatioWidth = 0
    var resizableAspectRatioHeight = 0
    var blockSleepSpamming = false
    var ignoreUnityKeyboardInitializationError = false

    init() {}

    // handle old 2.x settings where MulgChain did not exist yet
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier) ?? ""
        keymapping = try container.decodeIfPresent(Bool.self, forKey: .keymapping) ?? true
        sensitivity = try container.decodeIfPresent(Float.self, forKey: .sensitivity) ?? 50
        disableTimeout = try container.decodeIfPresent(Bool.self, forKey: .disableTimeout) ?? false
        displayRotation = try container.decodeIfPresent(Int.self, forKey: .displayRotation) ?? 0
        iosDeviceModel = try container.decodeIfPresent(String.self, forKey: .iosDeviceModel) ?? "iPad17,3"
        windowWidth = try container.decodeIfPresent(Int.self, forKey: .windowWidth) ?? 1920
        windowHeight = try container.decodeIfPresent(Int.self, forKey: .windowHeight) ?? 1080
        customScaler = try container.decodeIfPresent(Double.self, forKey: .customScaler) ?? 2.0
        resolution = try container.decodeIfPresent(Int.self, forKey: .resolution) ?? GameSettings().resolution
        aspectRatio = try container.decodeIfPresent(Int.self, forKey: .aspectRatio) ?? 1
        notch = try container.decodeIfPresent(Bool.self, forKey: .notch) ?? NSScreen.hasNotch()
        bypass = try container.decodeIfPresent(Bool.self, forKey: .bypass) ?? false
        discordActivity = try container.decodeIfPresent(DiscordActivity.self,
                                                        forKey: .discordActivity) ?? DiscordActivity()
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "3.0.0"
        mulgChain = try container.decodeIfPresent(Bool.self, forKey: .mulgChain) ?? true
        mulgChainDebugging = try container.decodeIfPresent(Bool.self, forKey: .mulgChainDebugging) ?? false
        inverseScreenValues = try container.decodeIfPresent(Bool.self, forKey: .inverseScreenValues) ?? false
        metalHUD = try container.decodeIfPresent(Bool.self, forKey: .metalHUD) ?? false
        windowFixMethod = try container.decodeIfPresent(Int.self, forKey: .windowFixMethod) ?? 0
        injectIntrospection = try container.decodeIfPresent(Bool.self, forKey: .injectIntrospection) ?? false
        rootWorkDir = try container.decodeIfPresent(Bool.self, forKey: .rootWorkDir) ?? true
        noKMOnInput = try container.decodeIfPresent(Bool.self, forKey: .noKMOnInput) ?? true
        enableScrollWheel = try container.decodeIfPresent(Bool.self, forKey: .enableScrollWheel) ?? true
        hideTitleBar = try container.decodeIfPresent(Bool.self, forKey: .hideTitleBar) ?? GameSettings().hideTitleBar
        floatingWindow = try container.decodeIfPresent(Bool.self, forKey: .floatingWindow) ?? false
        checkMicPermissionSync = try container.decodeIfPresent(Bool.self, forKey: .checkMicPermissionSync) ?? false
        limitMotionUpdateFrequency = try container.decodeIfPresent(Bool.self,
                                                                   forKey: .limitMotionUpdateFrequency) ?? false
        disableBuiltinMouse = try container.decodeIfPresent(Bool.self, forKey: .disableBuiltinMouse) ?? false
        resizableAspectRatioType = try container.decodeIfPresent(Int.self, forKey: .resizableAspectRatioType) ?? 0
        resizableAspectRatioWidth = try container.decodeIfPresent(Int.self, forKey: .resizableAspectRatioWidth) ?? 0
        resizableAspectRatioHeight = try container.decodeIfPresent(Int.self, forKey: .resizableAspectRatioHeight) ?? 0
        blockSleepSpamming = try container.decodeIfPresent(Bool.self, forKey: .blockSleepSpamming) ?? false
        ignoreUnityKeyboardInitializationError = try container.decodeIfPresent(
            Bool.self, forKey: .ignoreUnityKeyboardInitializationError) ?? false
    }
}

class AppSettings: ObservableObject, @unchecked Sendable {
    static var appSettingsDir: URL {
        let settingsFolder =
            GameRuntime.mulgContainer.appendingPathComponent("App Settings")
        if !FileManager.default.fileExists(atPath: settingsFolder.path) {
            do {
                try FileManager.default.createDirectory(at: settingsFolder,
                                                        withIntermediateDirectories: true,
                                                        attributes: [:])
            } catch {
                Log.shared.error(error)
            }
        }
        return settingsFolder
    }

    let info: AppInfo
    let settingsUrl: URL
    var openWithLLDB: Bool = false
    var openLLDBWithTerminal: Bool = true
    private var suppressPersistence = false
    private var persistenceBase: Data?
    private let store: SettingsStore
    @Published var persistenceProblem: String? = nil
    @Published var settings: AppSettingsData {
        didSet {
            if !suppressPersistence { encode() }
        }
    }

    init(_ info: AppInfo, store: SettingsStore = SettingsStore()) {
        self.info = info
        self.store = store
        settingsUrl = store.paths.settingsFile(for: info.bundleIdentifier)
        var defaults = AppSettingsData()
        defaults.bundleIdentifier = info.bundleIdentifier
        settings = defaults
        if !decode() {
            preserveUnreadableSettingsIfPresent()
            encode()
        }

        if settings.bundleIdentifier != info.bundleIdentifier {
            settings.bundleIdentifier = info.bundleIdentifier
        }
    }

    public func sync() {
        // The Performance tab and Mulg's menus also write this file; start from what is on disk.
        decode()
        settings.notch = NSScreen.hasNotch()
    }

    public func reset() {
        var defaults = AppSettingsData()
        defaults.bundleIdentifier = info.bundleIdentifier
        do {
            let data = try PropertyListEncoder().encode(defaults)
            _ = try store.saveLegacy(data, basedOn: nil, bundleIdentifier: info.bundleIdentifier, reset: true)
            _ = decode()
        } catch { Log.shared.error(error) }
    }

    @discardableResult
    public func decode() -> Bool {
        do {
            let data = try Data(contentsOf: settingsUrl)
            let decoded = try PropertyListDecoder().decode(AppSettingsData.self, from: data)
            suppressPersistence = true
            settings = decoded
            persistenceBase = try PropertyListEncoder().encode(decoded)
            suppressPersistence = false
            persistenceProblem = nil
            return true
        } catch {
            suppressPersistence = false
            if FileManager.default.fileExists(atPath: settingsUrl.path) {
                Log.shared.log(
                    "App settings decode failed for \(info.bundleIdentifier): \(error.localizedDescription)",
                    isError: true
                )
            }
            return false
        }
    }

    @discardableResult
    public func encode() -> Bool {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml

        do {
            let data = try store.saveLegacy(encoder.encode(settings), basedOn: persistenceBase,
                                                     bundleIdentifier: info.bundleIdentifier)
            let merged = try PropertyListDecoder().decode(AppSettingsData.self, from: data)
            suppressPersistence = true
            settings = merged
            persistenceBase = try encoder.encode(merged)
            suppressPersistence = false
            persistenceProblem = nil
            return true
        } catch {
            suppressPersistence = false
            if let persistenceBase,
               let saved = try? PropertyListDecoder().decode(AppSettingsData.self, from: persistenceBase) {
                suppressPersistence = true
                settings = saved
                suppressPersistence = false
            }
            persistenceProblem = error.localizedDescription
            Log.shared.log(
                "App settings write failed for \(info.bundleIdentifier): \(error.localizedDescription)",
                isError: true
            )
            return false
        }
    }

    private func preserveUnreadableSettingsIfPresent() {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: settingsUrl.path) else { return }
        let backupURL = settingsUrl.deletingPathExtension().appendingPathExtension("invalid.plist")
        do {
            try? fileManager.removeItem(at: backupURL)
            try fileManager.copyItem(at: settingsUrl, to: backupURL)
            Log.shared.log("Preserved unreadable app settings at \(backupURL.path)", isError: true)
        } catch {
            Log.shared.log(
                "Failed to preserve unreadable app settings for \(info.bundleIdentifier): " +
                    error.localizedDescription,
                isError: true
            )
        }
    }
}

extension NSScreen {
    public static func hasNotch() -> Bool {
        // check if any of the connected screens contains a notch
        return NSScreen.screens.contains { $0.safeAreaInsets.top != 0 }
    }

    private static func getMacModel() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        var modelIdentifier: String?

        if let modelData = IORegistryEntryCreateCFProperty(service, "model" as CFString, kCFAllocatorDefault, 0)
            .takeRetainedValue() as? Data {
            if let modelIdentifierCString = String(data: modelData, encoding: .utf8)?.cString(using: .utf8) {
                modelIdentifier = String(cString: modelIdentifierCString)
            }
        }
        IOObjectRelease(service)
        return modelIdentifier
    }
}
