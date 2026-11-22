import CryptoKit
import Foundation
import MulgContracts

/// Optional description shipped next to a plugin as `<name>.module.json`.
public struct PluginCard: Codable, Sendable, Equatable {
    public var id: String
    /// Runtime protocol the plugin was built for (§1.5 rule 11).
    public var runtimeProtocol: Int
    public var experimental: Bool

    public init(id: String, runtimeProtocol: Int, experimental: Bool) {
        self.id = id
        self.runtimeProtocol = runtimeProtocol
        self.experimental = experimental
    }
}

/// Loads plugin libraries from the game's `Frameworks/UserPlugins/` folder, but only trusted
/// ones (PLAN.md §1.5 rule 6).
///
/// Upstream loaded every `.dylib` there alphabetically with no checks. Here each file's
/// SHA-256 and metadata presence/content must match the app's installation records, unless the
/// user allowed unverified plugins for this game. Plugins with a card are also checked for
/// runtime compatibility, the per-game on/off switch and safe mode.
public struct PluginLoader: Sendable {
    public enum Decision: Sendable, Equatable {
        case load
        case skipUntrusted
        case skipHashMismatch
        case skipInvalidFile
        case skipSwitchedOff
        case skipIncompatible(pluginProtocol: Int)
        case skipInvalidCard
        case skipSafeMode
        case skipDependency(String)
    }

    public struct Result: Sendable, Equatable {
        public let fileName: String
        public let decision: Decision
        /// Set when loading was attempted and failed.
        public let loadError: String?
    }

    public static let folderName = "UserPlugins"

    public let folder: URL
    public let engine: EngineSettings
    public let safeMode: Bool
    public let minimalRecovery: Bool
    private let executable: URL?

    public init(folder: URL, engine: EngineSettings, safeMode: Bool, executable: URL? = Bundle.main.executableURL,
                minimalRecovery: Bool = false) {
        self.folder = folder
        self.engine = engine
        self.safeMode = safeMode
        self.minimalRecovery = minimalRecovery
        self.executable = executable
    }

    /// The game's plugin folder, if the game has one.
    public static func defaultFolder() -> URL? {
        Bundle.main.privateFrameworksURL?.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Plugin files in name order. Hidden files are skipped: a game on a drive that is not APFS/HFS+ (an
    /// exFAT games drive) carries an AppleDouble "._<name>.dylib" beside every plugin, which was then
    /// reported as an untrusted plugin or handed to dlopen.
    public func pluginFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names
            .filter { $0.hasSuffix(".dylib") && !$0.hasPrefix(".") }
            .sorted()
            .map { folder.appendingPathComponent($0, isDirectory: false) }
    }

    public func decide(for file: URL) -> Decision {
        guard !minimalRecovery else { return .skipSafeMode }
        guard let kind = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              kind.isRegularFile == true, kind.isSymbolicLink != true else {
            return .skipInvalidFile
        }
        let name = file.lastPathComponent
        if let expected = engine.trustedPluginHashes[name] {
            guard let actual = Self.sha256(of: file), actual.caseInsensitiveCompare(expected) == .orderedSame else {
                return .skipHashMismatch
            }
        } else if !engine.allowUnverifiedPlugins {
            return .skipUntrusted
        }

        let cardFile = file.deletingPathExtension().appendingPathExtension("module.json")
        let attributes = try? FileManager.default.attributesOfItem(atPath: cardFile.path)
        let hasCard = attributes != nil // Includes dangling links, which are not ordinary metadata.
        if hasCard, attributes?[.type] as? FileAttributeType != .typeRegular { return .skipInvalidCard }
        let cardData = hasCard ? try? Data(contentsOf: cardFile) : nil
        if let expected = engine.trustedPluginHashes[cardFile.lastPathComponent] {
            if expected == "absent" {
                guard !hasCard else { return .skipHashMismatch }
            } else {
                guard let cardData,
                      SHA256.hash(data: cardData).map({ String(format: "%02x", $0) }).joined()
                        .caseInsensitiveCompare(expected) == .orderedSame else {
                    return .skipHashMismatch
                }
            }
        } else if !engine.allowUnverifiedPlugins {
            // Older stamps are upgraded by the host only after bundle signature verification.
            return .skipUntrusted
        }
        if hasCard {
            // Decode the exact bytes verified above; do not reopen mutable metadata for policy.
            guard let cardData, let card = try? JSONDecoder().decode(PluginCard.self, from: cardData) else { return .skipInvalidCard }
            if !engine.isModuleEnabled(card.id) {
                return .skipSwitchedOff
            }
            if card.runtimeProtocol != MulgVersion.runtimeProtocol {
                return .skipIncompatible(pluginProtocol: card.runtimeProtocol)
            }
            if safeMode && card.experimental {
                return .skipSafeMode
            }
        } else if safeMode {
            // Plugins without a card are treated as experimental.
            return .skipSafeMode
        }
        return .load
    }

    /// Decides and loads every plugin; returns what happened to each.
    public func loadAll() -> [Result] {
        // Finish policy checks before any constructor can execute, including dependent plugins.
        let plan = pluginFiles().map { file in (file, preflight(for: file)) }
        return plan.map { file, decision in
            guard decision == .load else {
                return Result(fileName: file.lastPathComponent, decision: decision, loadError: nil)
            }
            if dlopen(file.path, RTLD_NOW) == nil {
                let message = dlerror().map { String(cString: $0) } ?? "unknown error"
                return Result(fileName: file.lastPathComponent, decision: decision, loadError: message)
            }
            return Result(fileName: file.lastPathComponent, decision: decision, loadError: nil)
        }
    }

    func preflight(for file: URL) -> Decision {
        let decision = decide(for: file)
        guard decision == .load else { return decision }
        struct Rejected: Error { let path: String }
        let pluginFolder = folder.resolvingSymlinksInPath().standardizedFileURL
        var visited: Set<URL> = []
        func expand(_ path: String, loader: URL) -> String {
            for (token, directory) in [("@loader_path", loader.deletingLastPathComponent()),
                                      ("@executable_path", executable?.deletingLastPathComponent())] {
                if let directory, path == token || path.hasPrefix(token + "/") {
                    return directory.path + path.dropFirst(token.count)
                }
            }
            return path
        }
        func systemContains(_ path: String) -> Bool {
            guard path.hasPrefix("/System/") || path.hasPrefix("/usr/lib/") else { return false }
            return MachOImage.systemContains(path)
        }
        func visit(_ path: URL, inherited: [String]) throws {
            let image = path.resolvingSymlinksInPath().standardizedFileURL
            // Check both the named file and its destination; aliases cannot hide a disabled plugin.
            for candidate in [path.standardizedFileURL, image]
                where candidate.deletingLastPathComponent().resolvingSymlinksInPath() == pluginFolder {
                guard decide(for: candidate) == .load else { throw Rejected(path: candidate.path) }
            }
            guard visited.insert(image).inserted else { return }
            let data = try MachOImage.arm64Slice(of: Data(contentsOf: image, options: .alwaysMapped))
            let paths = try MachOImage.runpaths(in: data).map { expand($0, loader: image) } + inherited
            for dependency in try MachOImage.dependencies(in: data) {
                var candidates = dependency.path.hasPrefix("@rpath/")
                    ? paths.map { $0 + "/" + dependency.path.dropFirst(7) }
                    : [expand(dependency.path, loader: image)]
                if dependency.path.hasPrefix("@rpath/libswift"), dependency.path.hasSuffix(".dylib") {
                    let name = String(dependency.path.dropFirst(7))
                    if !name.contains("/") { candidates += ["/System/iOSSupport/usr/lib/swift/" + name, "/usr/lib/swift/" + name] }
                }
                var found = false
                for candidate in candidates where candidate.hasPrefix("/") {
                    if systemContains(candidate) { found = true; break }
                    let next = URL(fileURLWithPath: candidate).standardizedFileURL
                    if FileManager.default.fileExists(atPath: next.path) {
                        try visit(next, inherited: paths)
                        found = true
                        break
                    }
                }
                if !found && !dependency.weak { throw Rejected(path: dependency.path) }
            }
        }
        do {
            let mainPaths: [String]
            if let executable {
                let data = try MachOImage.arm64Slice(of: Data(contentsOf: executable, options: .alwaysMapped))
                mainPaths = try MachOImage.runpaths(in: data).map { expand($0, loader: executable) }
            } else { mainPaths = [] }
            try visit(file, inherited: mainPaths)
            return .load
        } catch let failure as Rejected {
            return .skipDependency(failure.path)
        } catch {
            return .skipDependency("\(file.lastPathComponent): \(error)")
        }
    }

    /// SHA-256 of a file as lowercase hex, read in chunks.
    public static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            // read(upToCount:) returns nil at the end of the file, not empty data.
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 1 << 20) } catch { return nil }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
