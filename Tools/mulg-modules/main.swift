import Foundation

// mulg-modules: checks the module cards and writes MODULES.md and the app's copy of each
// card's status, ModuleStatus.generated.swift (PLAN.md §1.4–1.5).
//
//   swift run mulg-modules            check only
//   swift run mulg-modules write      check, then regenerate MODULES.md and
//                                     ModuleStatus.generated.swift
//   swift run mulg-modules verify     check, and fail if either is out of date
//   add --root <path> to point at the repository root explicitly

func repositoryRoot(arguments: [String]) -> URL {
    if let flag = arguments.firstIndex(of: "--root"), flag + 1 < arguments.count {
        return URL(fileURLWithPath: arguments[flag + 1], isDirectory: true).standardizedFileURL
    }
    let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let manager = FileManager.default
    // Run from the repository root (where `swift run` is used), or from a folder inside it.
    if manager.fileExists(atPath: current.appendingPathComponent("Modules").path) {
        return current.standardizedFileURL
    }
    return current.deletingLastPathComponent().standardizedFileURL
}

func run() -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())
    var positional = arguments
    if let flag = positional.firstIndex(of: "--root") {
        positional.removeSubrange(flag..<min(flag + 2, positional.count))
    }
    let command = positional.first ?? "check"
    let root = repositoryRoot(arguments: arguments)

    var registry = Registry(repositoryRoot: root)
    var errors: [String] = []
    do {
        errors += try registry.loadCards()
        if errors.isEmpty {
            errors += registry.checkCards()
            errors += try registry.checkOwnership()
            errors += registry.checkNewCodeFolders()
            errors += registry.checkLanguages()
        }
    } catch {
        errors.append(String(describing: error))
    }

    for error in errors {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    }
    if !errors.isEmpty {
        return 1
    }

    let outputs = [
        (registry.appRoot.appendingPathComponent("MODULES.md"), registry.renderModulesFile()),
        (registry.statusFile, registry.renderStatusFile())
    ]
    switch command {
    case "write":
        for (file, generated) in outputs {
            do {
                try generated.write(to: file, atomically: true, encoding: .utf8)
            } catch {
                FileHandle.standardError.write(Data("error: could not write \(file.lastPathComponent): \(error)\n".utf8))
                return 1
            }
        }
    case "verify":
        for (file, generated) in outputs where (try? String(contentsOf: file, encoding: .utf8)) != generated {
            FileHandle.standardError.write(
                Data("error: \(file.lastPathComponent) is out of date; run swift run mulg-modules write\n".utf8))
            return 1
        }
    case "check":
        break
    default:
        FileHandle.standardError.write(Data("error: unknown command '\(command)' (check, write, verify)\n".utf8))
        return 2
    }

    let upstreamFiles = registry.owners.count
    print("ok: \(registry.cards.count) modules, \(upstreamFiles) upstream source files, each owned exactly once")
    return 0
}

exit(run())
