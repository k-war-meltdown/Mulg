#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import MachO

/// Orders game SDK constructors after the runtime and explicitly links the storage
/// adapters they use. Existing library positions and unrelated imports are preserved.
/// Objective-C +load ordering is independent of C constructor dependencies.
public enum GameRuntimeDependencies {
    private static func isRuntime(_ path: String) -> Bool {
        RuntimeInstaller.isRuntimeLibrary(path)
            || path.hasSuffix("/GameRuntime.framework/MulgKit")
    }

    private static func targets(in app: URL, mainExecutable: URL) throws -> [URL] {
        let root = app.standardizedFileURL.path + "/"
        let binaries = GameInstaller.findBinaries(in: app)
        let shared = try DependencyValidation.librariesUsedByOtherExecutables(binaries: binaries, main: mainExecutable)
        return try binaries.filter { file in
            if file.standardizedFileURL == mainExecutable.standardizedFileURL { return true }
            let path = file.standardizedFileURL.path
            guard path.hasPrefix(root),
                  !shared.contains(file.resolvingSymlinksInPath().standardizedFileURL) else { return false }
            let components = String(path.dropFirst(root.count)).split(separator: "/")
            guard !components.contains(where: {
                      $0 == "MulgRuntime.framework" || $0 == "GameRuntime.framework" || $0 == "MulgKit.framework"
                          || $0 == "MulgBridge.bundle" || $0 == "MulgAppKit.bundle" || $0 == "MulgKit.dylib"
                          || $0 == "UserPlugins" || $0.hasSuffix(".app") || $0.hasSuffix(".appex") || $0.hasSuffix(".xpc")
                  }) else { return false }
            let binary = try MachOBinary.arm64Slice(of: Data(contentsOf: file, options: .alwaysMapped))
            let platform = try MachOBinary.buildInfo(of: binary)?.platform
            return binary.uint32(at: 12) == UInt32(MH_DYLIB)
                && platform == UInt32(PLATFORM_MACCATALYST)
        }
    }

    /// The runtime a target should link. The main executable always does. A bundled SDK
    /// that inspects the loaded-image list stays as shipped: native system providers and no
    /// runtime dependency. Native container paths still reach the game's data through the
    /// existing directory aliases.
    private static func runtime(for file: URL, mainExecutable: URL, runtimePath: String?) throws -> String? {
        guard let runtimePath, file.standardizedFileURL != mainExecutable.standardizedFileURL else { return runtimePath }
        let binary = try MachOBinary.arm64Slice(of: Data(contentsOf: file, options: .alwaysMapped))
        return try MachOBinary.inspectsLoadedImages(binary) ? nil : runtimePath
    }

    private static func linked(in file: URL, runtimePath: String? = nil) throws -> Set<String> {
        let binary = try MachOBinary.arm64Slice(of: Data(contentsOf: file, options: .alwaysMapped))
        return Set(try MachOBinary.loadedLibraries(in: binary).filter { isRuntime($0) || $0 == runtimePath })
    }

    /// Operates only on a BundleTransaction/install staging copy. Removal first restores
    /// native storage providers, before removing their runtime dependency and its ordinal.
    @discardableResult
    public static func synchronize(in app: URL, mainExecutable: URL, runtimePath: String?) throws -> [URL] {
        let files = try targets(in: app, mainExecutable: mainExecutable)
        guard files.contains(where: { $0.standardizedFileURL == mainExecutable.standardizedFileURL }) else {
            throw GameInstaller.Failure.missingExecutable(mainExecutable.path)
        }
        var modified: [URL] = []
        for file in files {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let before = try Data(contentsOf: file)
            let previous = try linked(in: file, runtimePath: runtimePath)
            let fileRuntime = try runtime(for: file, mainExecutable: mainExecutable, runtimePath: runtimePath)
            let wanted = Set(fileRuntime.map { [$0] } ?? [])
            // Restore all old adapter providers before stale dependency ordinals can disappear.
            var restored = try MachOBinary.arm64Slice(of: before)
            if previous != wanted, try MachOBinary.routeStorageImports(&restored, runtimePath: nil) {
                try restored.write(to: file, options: .atomic)
            }
            if previous != wanted {
                let replacement: [String: String]
                if let fileRuntime, !previous.contains(fileRuntime), let first = previous.sorted().first {
                    replacement = [first: fileRuntime]
                } else {
                    replacement = [:]
                }
                try MachOBinary.editLibraries(at: file, adding: fileRuntime.map { [$0] } ?? [],
                                             removing: previous.sorted(), replacing: replacement)
            }
            if runtimePath != nil {
                var routed = try MachOBinary.arm64Slice(of: Data(contentsOf: file))
                let allocatorsChanged = file.standardizedFileURL == mainExecutable.standardizedFileURL
                    ? try MachOBinary.restoreGameAllocatorExports(&routed) > 0 : false
                let pathsChanged = try MachOBinary.repairSystemFrameworkPaths(&routed)
                let importsChanged = try fileRuntime.map { try MachOBinary.routeStorageImports(&routed, runtimePath: $0) } ?? false
                if allocatorsChanged || pathsChanged || importsChanged {
                    try routed.write(to: file, options: .atomic)
                }
            }
            if try Data(contentsOf: file) != before {
                if let mode = attributes[.posixPermissions] {
                    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
                }
                modified.append(file)
            }
        }
        return modified
    }

    /// Sign modified SDKs and their containing bundles before the main app is sealed.
    public static func resignChangedLibraries(_ modified: [URL], in app: URL, mainExecutable: URL) throws {
        let libraries = modified.filter { $0.standardizedFileURL != mainExecutable.standardizedFileURL }
        guard !libraries.isEmpty else { return }
        let plan = SigningPlan(app: app, binaries: libraries, entitlements: app)
        for stage in plan.stages {
            for item in stage {
                try SigningPlan.codesign(["--force", "--sign", "-", "--preserve-metadata=entitlements,requirements", item.path])
            }
        }
    }

    public static func isCurrent(in app: URL, mainExecutable: URL, runtimePath: String) throws -> Bool {
        let files = try targets(in: app, mainExecutable: mainExecutable)
        guard files.contains(where: { $0.standardizedFileURL == mainExecutable.standardizedFileURL }) else { return false }
        for file in files {
            let fileRuntime = try runtime(for: file, mainExecutable: mainExecutable, runtimePath: runtimePath)
            guard try linked(in: file, runtimePath: runtimePath) == Set(fileRuntime.map { [$0] } ?? []) else { return false }
            var binary = try MachOBinary.arm64Slice(of: Data(contentsOf: file, options: .alwaysMapped))
            if file.standardizedFileURL == mainExecutable.standardizedFileURL,
               try MachOBinary.restoreGameAllocatorExports(&binary) > 0 { return false }
            if try MachOBinary.repairSystemFrameworkPaths(&binary) { return false }
            if try MachOBinary.routeStorageImports(&binary, runtimePath: fileRuntime) { return false }
        }
        return true
    }
}
#endif
