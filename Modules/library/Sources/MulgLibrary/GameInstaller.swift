// Host-side module: the Mulg app is a native macOS app, never Mac Catalyst.
#if os(macOS) && !targetEnvironment(macCatalyst)
import CryptoKit
import Foundation
import MulgContracts

/// Turns an unzipped iOS app into one macOS can run (PLAN.md §16.3 E7–E9): converts every
/// binary in parallel, links the Mulg runtime into the main executable, installs plugins,
/// signs everything once from the inside out and records what it did in the game's settings.
///
/// Replaces upstream `Installer.swift`'s convert/inject/sign steps. Unzipping, entitlements
/// and wrapping the app stay in the Mulg app for now.
public enum GameInstaller {
    public enum Failure: Error, Equatable, Sendable {
        case missingInfo(String)
        case missingExecutable(String)
        /// Upstream `PROHIBITED_APPS`: games whose makers block Mulg (§15).
        case prohibited(bundleIdentifier: String)
        /// App Store encryption is still on; the game must be decrypted first.
        case encrypted(file: String)
        case binary(file: String, MachOBinary.Failure)
        case signing(file: String, status: Int32, output: String)
    }

    /// Copied from upstream `MulgGame.swift`. Keep in sync; never shorten it (PLAN.md §15).
    public static let prohibitedBundleIdentifiers: Set<String> = [
        "com.activision.callofduty.shooter",
        "com.ea.ios.apexlegendsmobilefps",
        "com.tencent.tmgp.cod",
        "com.tencent.ig",
        "com.pubg.newstate",
        "com.pubg.imobile",
        "com.tencent.tmgp.pubgmhd",
        "com.dts.freefireth",
        "com.dts.freefiremax",
        "vn.vng.codmvn",
        "com.ngame.allstar.eu",
        "com.axlebolt.standoff2",
        "com.tencent.lolm"
    ]

    /// Where the app puts the runtime; the game loads it from here.
    public static func runtimePath(home: URL = ContainerPaths.realHomeDirectory()) -> String {
        home.appendingPathComponent("Library/Frameworks/MulgRuntime.framework/MulgRuntime").path
    }

    /// Everything the install needs besides the app itself.
    public struct Options: Sendable {
        public var runtimePath: String?
        public var entitlements: URL
        public var plugins: [URL]
        /// The host already warns before allowing a blocked game to be installed.
        public var allowProhibited: Bool
        /// `LSApplicationCategoryType` to write, for example `gamesCategory` for Game Mode.
        public var category: String?
        public var allowRestrictedEntitlements = false

        public init(runtimePath: String? = GameInstaller.runtimePath(), entitlements: URL, plugins: [URL] = [],
                    category: String? = nil, allowProhibited: Bool = false, allowRestrictedEntitlements: Bool = false) {
            self.runtimePath = runtimePath
            self.entitlements = entitlements
            self.plugins = plugins
            self.category = category
            self.allowRestrictedEntitlements = allowRestrictedEntitlements
            self.allowProhibited = allowProhibited
        }
    }

    /// Runs the pipeline. `sign` is swappable so tests can skip `codesign`.
    public static func install(
        app: URL,
        options: Options,
        settings: inout GameSettings,
        prepare: @Sendable (URL) async throws -> Void = { _ in },
        preflight: @Sendable (URL, [URL]) throws -> Void = { try DependencyValidation.validate(app: $0, binaries: $1) },
        sign: @Sendable (SigningPlan) async throws -> Void = { try await $0.run() }
    ) async throws {
        let info = try appInfo(app)
        guard options.allowProhibited || !prohibitedBundleIdentifiers.contains(info.bundleIdentifier) else {
            throw Failure.prohibited(bundleIdentifier: info.bundleIdentifier)
        }
        let mainExecutable = app.appendingPathComponent(info.executable)
        let binaries = findBinaries(in: app, including: mainExecutable)
        let capabilities = try BundleCapabilities(app: app, binaries: binaries,
                                                   allowRestricted: options.allowRestrictedEntitlements)
        guard binaries.contains(where: { $0.standardizedFileURL == mainExecutable.standardizedFileURL }) else {
            throw Failure.missingExecutable(mainExecutable.path)
        }
        try await convertBinaries(
            binaries,
            keepSDK: settings.mulg.engine.keepGameSDKVersion,
            runtimePath: options.runtimePath,
            mainExecutable: mainExecutable
        )
        if let runtimePath = options.runtimePath {
            try GameRuntimeDependencies.synchronize(in: app, mainExecutable: mainExecutable, runtimePath: runtimePath)
        }
        try await prepare(app)
        if options.runtimePath != nil {
            try synchronizePointerInput(in: app, settings: settings)
        }
        try installPlugins(options.plugins, into: app)
        if let category = options.category {
            try setCategory(category, of: app)
        }

        let preparedBinaries = findBinaries(in: app, including: mainExecutable)
        try preflight(app, preparedBinaries)
        let signing = SigningPlan(app: app, binaries: preparedBinaries, entitlements: options.entitlements,
                                  nestedEntitlements: capabilities.entitlements)
        if !capabilities.unavailable.isEmpty {
            try JSONEncoder().encode(capabilities.unavailable)
                .write(to: app.appendingPathComponent("MulgCapabilities.json"), options: .atomic)
        }
        try await sign(signing)

        // Signing rewrites plugin files, so hash them afterwards (§1.5 rule 6).
        if options.runtimePath != nil {
            settings.mulg.engine.trustedPluginHashes = pluginHashes(in: app)
            settings.mulg.engine.injectedRuntimeVersion = MulgVersion.current
            settings.mulg.engine.injectedRuntimeProtocol = MulgVersion.runtimeProtocol
        }
    }

    /// macOS turns on Game Mode for apps in this category.
    public static let gamesCategory = "public.app-category.games"

    // MARK: Steps

    private static let indirectInputKey = "UIApplicationSupportsIndirectInputEvents"
    private static let managedPointerInputKey = "MulgManagedDirectPointerInput"

    /// UIKit defaults an absent input key to indirect-pointer contacts on iOS 17+.
    /// Active mapped touch gameplay requests direct contacts. Disabled mapping must keep
    /// the game's native pointer declaration even if its saved backend is touch. Respect
    /// explicit app declarations; track our addition so changing backend/removal restores
    /// the original absent key. Call only on the staging copy, before signing.
    public static func synchronizePointerInput(in app: URL, settings: GameSettings) throws {
        try updatePointerInput(in: app, direct: mapsPointerToTouch(settings))
    }

    public static func restorePointerInput(in app: URL) throws {
        try updatePointerInput(in: app, direct: false)
    }

    public static func pointerInputIsCurrent(in app: URL, settings: GameSettings) throws -> Bool {
        guard var info = infoPlist(app) else { throw Failure.missingInfo(app.path) }
        return !reconcilePointerInput(&info, direct: mapsPointerToTouch(settings))
    }

    private static func mapsPointerToTouch(_ settings: GameSettings) -> Bool {
        !TFTMouseCompatibility.applies(to: settings.bundleIdentifier)
            && settings.keymapping && settings.mulg.controls.playMode == .touch
            && !settings.mulg.engine.disabledModules.contains("controls")
    }

    private static func updatePointerInput(in app: URL, direct: Bool) throws {
        guard var info = infoPlist(app) else { throw Failure.missingInfo(app.path) }
        guard reconcilePointerInput(&info, direct: direct) else { return }
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"), options: .atomic)
    }

    private static func reconcilePointerInput(_ info: inout [String: Any], direct: Bool) -> Bool {
        if info[managedPointerInputKey] as? Bool == true {
            if info[indirectInputKey] as? Bool == false {
                guard !direct else { return false }
                info.removeValue(forKey: indirectInputKey)
            }
            // If somebody changed the managed value, preserve their new declaration.
            info.removeValue(forKey: managedPointerInputKey)
            return true
        }
        guard direct, info[indirectInputKey] == nil else { return false }
        info[indirectInputKey] = false
        info[managedPointerInputKey] = true
        return true
    }

    /// Caller holds the session lease. Shared by plugin edits and runtime removal.
    public static func editInstalled(app: URL, bundleIdentifier: String, paths: ContainerPaths = .current(),
                                     companions: [URL: URL] = [:],
                                     prepare: (URL) throws -> Void, sign: (URL) throws -> Void,
                                     verify: (URL) throws -> Void = BundleTransaction.verifySignature) throws {
        try BundleTransaction.recover(bundleIdentifier, paths: paths, verify: verify)
        let files = FileManager.default
        let scratch = try BundleTransaction.workingDirectory(for: app)
        defer { try? files.removeItem(at: scratch) }
        let working = scratch.appendingPathComponent(app.lastPathComponent)
        try BundleTransaction.copy(app, to: working)
        try prepare(working)
        try sign(working)
        try BundleTransaction.replace(working, at: app, bundleIdentifier: bundleIdentifier,
                                      paths: paths, companions: companions, verify: verify)
    }

    /// Caller holds the session lease. Metadata is read from the staging copy, never a stale UI snapshot.
    public static func editMetadata(app: URL, bundleIdentifier: String, paths: ContainerPaths = .current(),
                                    update: (inout [String: Any]) throws -> Void,
                                    sign: (URL) throws -> Void,
                                    verify: (URL) throws -> Void = BundleTransaction.verifySignature) throws {
        try editInstalled(app: app, bundleIdentifier: bundleIdentifier, paths: paths, prepare: { working in
            guard var info = infoPlist(working) else { throw Failure.missingInfo(working.path) }
            try update(&info)
            try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
                .write(to: working.appendingPathComponent("Info.plist"), options: .atomic)
        }, sign: sign, verify: verify)
    }

    static func appInfo(_ app: URL) throws -> (bundleIdentifier: String, executable: String) {
        guard let info = infoPlist(app),
              let identifier = info["CFBundleIdentifier"] as? String,
              let executable = info["CFBundleExecutable"] as? String else {
            throw Failure.missingInfo(app.appendingPathComponent("Info.plist").path)
        }
        return (identifier, executable)
    }

    /// The app's `LSApplicationCategoryType`. Changing it breaks the signature, so it is
    /// written before signing (or the app is signed again afterwards).
    public static func category(of app: URL) -> String? {
        infoPlist(app)?["LSApplicationCategoryType"] as? String
    }

    public static func setCategory(_ category: String, of app: URL) throws {
        guard var info = infoPlist(app) else { throw Failure.missingInfo(app.appendingPathComponent("Info.plist").path) }
        info["LSApplicationCategoryType"] = category
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"), options: .atomic)
    }

    static func infoPlist(_ app: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Info.plist")) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// Files with no extension or `.dylib` whose header says Mach-O (thin, universal or
    /// 64-bit universal).
    public static func findBinaries(in app: URL, including mainExecutable: URL? = nil) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: keys) else { return [] }
        return files.compactMap { $0 as? URL }.filter { file in
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let handle = try? FileHandle(forReadingFrom: file) else { return false }
            defer { try? handle.close() }
            return MachOBinary.isMachOHeader((try? handle.read(upToCount: 4)) ?? Data())
        }
    }

    /// Converts all binaries at once. Each file is memory-mapped, so only the parts the
    /// rewrite touches are read and the result is written back in one go.
    public static func convertBinaries(_ files: [URL], keepSDK: Bool, runtimePath: String?, mainExecutable: URL) async throws {
        try await BoundedWork.run(files) { file in
            let isMain = file.standardizedFileURL == mainExecutable.standardizedFileURL
            let original = try Data(contentsOf: file, options: .alwaysMapped)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            do {
                let slice = try MachOBinary.arm64Slice(of: original)
                if try MachOBinary.isEncrypted(slice) {
                    throw Failure.encrypted(file: file.lastPathComponent)
                }
                var converted = try MachOBinary.convertForMac(slice, keepSDK: keepSDK)
                if isMain, let runtimePath {
                    try MachOBinary.restoreGameAllocatorExports(&converted)
                    try MachOBinary.addLibrary(&converted, path: runtimePath)
                }
                try Task.checkCancellation()
                try converted.write(to: file, options: .atomic)
                if let mode = attributes[.posixPermissions] {
                    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
                }
            } catch let failure as MachOBinary.Failure {
                throw Failure.binary(file: file.lastPathComponent, failure)
            }
        }
    }

    /// Plugins go to `Frameworks/UserPlugins/`, with their card (`<name>.module.json`) if
    /// one sits next to them.
    public static func installPlugins(_ plugins: [URL], into app: URL) throws {
        guard !plugins.isEmpty else { return }
        let folder = pluginFolder(in: app)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for plugin in plugins {
            let card = plugin.deletingPathExtension().appendingPathExtension("module.json")
            for file in [plugin, card] where FileManager.default.fileExists(atPath: file.path) {
                let target = folder.appendingPathComponent(file.lastPathComponent)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: file, to: target)
            }
        }
    }

    /// Plugin/card SHA-256 records; a missing card is bound by an explicit "absent" marker.
    public static func pluginHashes(in app: URL) -> [String: String] {
        let folder = pluginFolder(in: app)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var hashes: [String: String] = [:]
        for file in files where file.pathExtension == "dylib" {
            // ponytail: reads each plugin whole; plugins are small. Stream it if that changes.
            guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { continue }
            hashes[file.lastPathComponent] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let card = file.deletingPathExtension().appendingPathExtension("module.json")
            if !FileManager.default.fileExists(atPath: card.path) {
                hashes[card.lastPathComponent] = "absent"
            } else if let data = try? Data(contentsOf: card, options: .alwaysMapped) {
                hashes[card.lastPathComponent] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
        }
        return hashes
    }

    /// Same folder name as the engine's `PluginLoader.folderName`.
    static func pluginFolder(in app: URL) -> URL {
        app.appendingPathComponent("Frameworks/UserPlugins", isDirectory: true)
    }

    /// Replaces an installed game only after the staged copy verifies. A previous app or library
    /// link is kept until the new app is reachable, so failed updates leave the old one playable.
    public static func destination(bundleIdentifier: String, in folder: URL, library: URL) -> URL {
        let link = library.appendingPathComponent(bundleIdentifier + ".app")
        if folder.standardizedFileURL == library.standardizedFileURL,
           (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil {
            return link.resolvingSymlinksInPath()
        }
        return folder.appendingPathComponent(bundleIdentifier + ".app")
    }

    public static func place(_ app: URL, bundleIdentifier: String, in folder: URL, library: URL,
                             leasePaths: ContainerPaths = .current(),
                             verify: (URL) throws -> Void = BundleTransaction.verifySignature) throws -> URL {
        let lease = try GameSessionLease(bundleIdentifier: bundleIdentifier, paths: leasePaths)
        defer { withExtendedLifetime(lease) {} }
        guard !GameWatcher.isRunning(bundleIdentifier) else { throw GameSessionLease.Failure.busy }
        try BundleTransaction.recover(bundleIdentifier, paths: leasePaths, verify: verify)
        let files = FileManager.default
        let name = bundleIdentifier + ".app"
        let link = library.appendingPathComponent(name)
        let previousTarget = (try? files.destinationOfSymbolicLink(atPath: link.path))
            .map { URL(fileURLWithPath: $0) }
        // A source update keeps a game in its existing external folder.
        let location = destination(bundleIdentifier: bundleIdentifier, in: folder, library: library)
        let oldExternal = previousTarget.flatMap { $0.standardizedFileURL == location.standardizedFileURL ? nil : $0 }
        try files.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.createDirectory(at: library, withIntermediateDirectories: true)
        try BundleTransaction.replace(app, at: location, bundleIdentifier: bundleIdentifier,
                                      link: link, paths: leasePaths, verify: verify)
        try GameDataStorage.prepare(for: location, bundleIdentifier: bundleIdentifier, paths: leasePaths, sessionLease: lease)
        if let oldExternal { try? files.removeItem(at: oldExternal) }
        return location
    }
}

/// One signing pass from the inside out (§16.3 E7). Nested items are signed before the
/// bundle that contains them; items at the same depth are signed in parallel; the app is
/// signed last, once, with its entitlements. No `--deep`.
public struct SigningPlan: Sendable, Equatable {
    /// Each stage runs after the previous one; items within a stage run in parallel.
    public let stages: [[URL]]
    public let app: URL
    public let entitlements: URL
    public let nestedEntitlements: [URL: Data]

    /// Bundles that carry their own signature.
    static let bundleExtensions: Set<String> = ["framework", "appex", "app", "xpc", "bundle"]

    public init(app: URL, binaries: [URL], entitlements: URL, nestedEntitlements: [URL: Data] = [:]) {
        let root = app.standardizedFileURL.pathComponents
        var items: Set<URL> = []
        for binary in binaries.map(\.standardizedFileURL) {
            let parts = binary.pathComponents
            // Every nested bundle on the way to the binary is signed on its own.
            for depth in root.count..<(parts.count - 1) where Self.bundleExtensions.contains((parts[depth] as NSString).pathExtension) {
                items.insert(URL(fileURLWithPath: NSString.path(withComponents: Array(parts[...depth])), isDirectory: true))
            }
            // A bundle's main binary is signed with the bundle.
            let owners = [app] + items.filter { Self.bundleExtensions.contains($0.pathExtension) }
            let isBundleMain = owners.contains { bundle in
                let plists = ["Info.plist", "Resources/Info.plist", "Contents/Info.plist"]
                let name = plists.compactMap { relative -> String? in
                    guard let data = try? Data(contentsOf: bundle.appendingPathComponent(relative)),
                          let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
                    return info["CFBundleExecutable"] as? String
                }.first ?? bundle.deletingPathExtension().lastPathComponent
                return [bundle.appendingPathComponent(name), bundle.appendingPathComponent("Contents/MacOS/" + name)]
                    .contains { $0.resolvingSymlinksInPath() == binary.resolvingSymlinksInPath() }
            }
            if !isBundleMain {
                items.insert(binary)
            }
        }
        // A path with more components can only be inside one with fewer, never the other way.
        let byDepth = Dictionary(grouping: items) { $0.pathComponents.count }
        self.stages = byDepth.keys.sorted(by: >).map { byDepth[$0]!.sorted { $0.path < $1.path } }
        self.app = app.standardizedFileURL
        self.entitlements = entitlements
        self.nestedEntitlements = nestedEntitlements
    }

    /// The `codesign` arguments for one item; the app gets its entitlements. Always ad hoc: macOS
    /// ties a game's sandbox container to how it was signed, so a game first signed ad hoc must
    /// stay ad hoc or its container fails the integrity check at launch.
    public func arguments(for item: URL) -> [String] {
        var arguments = ["--force", "--sign", "-"]
        if item == app {
            arguments += ["--entitlements", entitlements.path]
            // Asked once per game for permissions, not again after every re-sign (StableSigning).
            arguments += StableSigning.requirementArguments(bundleIdentifier: StableSigning.bundleIdentifier(ofApp: app))
        }
        return arguments + [item.path]
    }

    public func run() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var files: [URL: URL] = [:]
        for (item, data) in nestedEntitlements where item != app {
            let file = folder.appendingPathComponent(UUID().uuidString + ".plist")
            try data.write(to: file)
            files[item] = file
        }
        let entitlementFiles = files
        for stage in stages {
            try await BoundedWork.run(stage) { item in
                var arguments = arguments(for: item)
                if let file = entitlementFiles[item] {
                    arguments.insert(contentsOf: ["--entitlements", file.path], at: arguments.count - 1)
                }
                try Self.codesign(arguments)
            }
        }
        try Task.checkCancellation()
        try Self.codesign(arguments(for: app))
    }

    static func codesign(_ arguments: [String]) throws {
        do {
            try Command.run("/usr/bin/codesign", arguments)
        } catch let failure as Command.Failure {
            throw GameInstaller.Failure.signing(file: arguments.last ?? "", status: failure.status, output: failure.output)
        }
    }
}
#endif
