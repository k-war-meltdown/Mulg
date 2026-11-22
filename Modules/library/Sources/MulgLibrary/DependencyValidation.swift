#if os(macOS) && !targetEnvironment(macCatalyst)
import Darwin
import Foundation
import MulgContracts

/// Checks loader paths without loading or executing untrusted game code.
public enum DependencyValidation {
    public struct Failure: Error, Sendable, CustomStringConvertible, LocalizedError {
        public let image: String
        public let dependency: String
        public var description: String { "\(image): required dependency is unavailable: \(dependency)" }
        public var errorDescription: String? { description }
    }

    public static func validate(app: URL, binaries: [URL],
                                systemContains: (String) -> Bool = systemContains) throws {
        let executable = app.appendingPathComponent(try GameInstaller.appInfo(app).executable)
        var visitedByProcess: [URL: Set<URL>] = [:]
        for root in [executable] + binaries {
            // Frameworks inherit the main process. Embedded apps/extensions/XPC services have
            // their own executable directory and must not borrow the game's runpath stack.
            let process = executableContext(for: root, app: app, main: executable)
            if visitedByProcess[process]?.contains(root.resolvingSymlinksInPath().standardizedFileURL) == true { continue }
            let main = try MachOBinary.arm64Slice(of: Data(contentsOf: process, options: .alwaysMapped))
            let mainPaths = try expandedRunpaths(main, loader: process, executable: process, inherited: [])
            var visited = visitedByProcess[process] ?? []
            func visit(_ image: URL, inherited: [String]) throws {
                let image = image.resolvingSymlinksInPath().standardizedFileURL
                guard visited.insert(image).inserted else { return }
                let data = try MachOBinary.arm64Slice(of: Data(contentsOf: image, options: .alwaysMapped))
                if let build = try MachOBinary.buildInfo(of: data),
                   ![UInt32(1), 6].contains(build.platform) || build.minimumOS.major > 27 {
                    throw Failure(image: image.path, dependency: "unsupported platform/deployment version")
                }
                let paths = try expandedRunpaths(data, loader: image, executable: process, inherited: inherited)
                for dependency in try MachOBinary.dependencies(in: data) {
                    var candidates: [String]
                    if dependency.path.hasPrefix("@rpath/") {
                        candidates = paths.map { $0 + "/" + dependency.path.dropFirst(7) }
                    } else {
                        candidates = [expand(dependency.path, loader: image, executable: process)]
                    }
                    if dependency.path.hasPrefix("@rpath/libswift"), dependency.path.hasSuffix(".dylib") {
                        let name = String(dependency.path.dropFirst(7))
                        if !name.contains("/") {
                            candidates += ["/System/iOSSupport/usr/lib/swift/" + name, "/usr/lib/swift/" + name]
                        }
                    }
                    var found = false
                    for path in candidates {
                        guard path.hasPrefix("/") else { continue }
                        let system = path.hasPrefix("/System/") || path.hasPrefix("/usr/lib/")
                        if system && systemContains(path) { found = true; break }
                        let file = URL(fileURLWithPath: path).standardizedFileURL
                        if FileManager.default.fileExists(atPath: file.path) {
                            if !system { try visit(file, inherited: paths) }
                            found = true
                            break
                        }
                    }
                    if !found && !dependency.weak {
                        throw Failure(image: image.path, dependency: dependency.path)
                    }
                }
            }
            try visit(root, inherited: mainPaths)
            visitedByProcess[process] = visited
        }
    }

    static func executableContext(for image: URL, app: URL, main: URL) -> URL {
        var bundle = image.deletingLastPathComponent()
        while bundle.pathComponents.count > app.pathComponents.count {
            if ["app", "appex", "xpc"].contains(bundle.pathExtension) {
                for plist in ["Info.plist", "Contents/Info.plist"] {
                    guard let data = try? Data(contentsOf: bundle.appendingPathComponent(plist)),
                          let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                          let name = info["CFBundleExecutable"] as? String else { continue }
                    return bundle.appendingPathComponent(plist.hasPrefix("Contents/") ? "Contents/MacOS/" + name : name)
                }
            }
            bundle.deleteLastPathComponent()
        }
        return main
    }

    /// A game and its extension/helper can share an SDK stored outside the helper bundle.
    /// Adding the game runtime to that SDK would also inject it into the helper process.
    /// Resolve the helper's dependency graph with its own executable/runpath context first.
    static func librariesUsedByOtherExecutables(binaries: [URL], main: URL) throws -> Set<URL> {
        let known = Set(binaries.map { $0.resolvingSymlinksInPath().standardizedFileURL })
        let main = main.resolvingSymlinksInPath().standardizedFileURL
        var shared: Set<URL> = []
        for executable in known where executable != main {
            let data = try MachOBinary.arm64Slice(of: Data(contentsOf: executable, options: .alwaysMapped))
            guard data.uint32(at: 12) == 2 /* MH_EXECUTE */ else { continue }
            var visited: Set<URL> = []
            func visit(_ image: URL, inherited: [String]) throws {
                guard visited.insert(image).inserted else { return }
                let binary = try MachOBinary.arm64Slice(of: Data(contentsOf: image, options: .alwaysMapped))
                let paths = try expandedRunpaths(binary, loader: image, executable: executable, inherited: inherited)
                for dependency in try MachOBinary.dependencies(in: binary) {
                    let candidates: [String]
                    if dependency.path.hasPrefix("@rpath/") {
                        candidates = paths.map { $0 + "/" + dependency.path.dropFirst(7) }
                    } else {
                        candidates = [expand(dependency.path, loader: image, executable: executable)]
                    }
                    for path in candidates where path.hasPrefix("/") {
                        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
                        if known.contains(file) {
                            try visit(file, inherited: paths)
                            break
                        }
                        // dyld uses the first existing candidate, even when it is external.
                        if FileManager.default.fileExists(atPath: path) || systemContains(path) { break }
                    }
                }
            }
            try visit(executable, inherited: [])
            shared.formUnion(visited)
        }
        return shared
    }

    private static func expandedRunpaths(_ data: Data, loader: URL, executable: URL,
                                         inherited: [String]) throws -> [String] {
        try MachOBinary.runpaths(in: data).map { expand($0, loader: loader, executable: executable) } + inherited
    }

    private static func expand(_ path: String, loader: URL, executable: URL) -> String {
        for (token, directory) in [("@loader_path", loader.deletingLastPathComponent()),
                                    ("@executable_path", executable.deletingLastPathComponent())] {
            if path == token { return directory.path }
            if path.hasPrefix(token + "/") { return directory.path + path.dropFirst(token.count) }
        }
        return path
    }

    /// System images commonly live only in the shared cache, not as files on disk.
    public static func systemContains(_ path: String) -> Bool {
        MachOImage.systemContains(path)
    }
}
#endif
