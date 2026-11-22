import Foundation
@preconcurrency import Yams

/// Loads the module cards and checks every rule in PLAN.md §1.5 against the repository.
struct Registry {
    /// The repository root (contains Host/, Runtime/, Modules/ and Package.swift).
    let repositoryRoot: URL
    /// Where Modules/ and MODULES.md live: the repository root since the folders were merged.
    var appRoot: URL { repositoryRoot }

    /// Upstream source folders whose files must each belong to exactly one module.
    static let upstreamRoots = ["Host", "Runtime"]
    static let sourceExtensions: Set<String> = ["swift", "m", "mm", "h", "c", "cpp"]
    /// Languages the language rule forbids outside the untouched upstream and vendored code.
    static let forbiddenExtensions: Set<String> = ["py", "rb", "js", "ts"]

    private(set) var cards: [String: ModuleCard] = [:]
    private(set) var owners: [String: [String]] = [:]

    init(repositoryRoot: URL) {
        self.repositoryRoot = repositoryRoot
    }

    // MARK: Loading

    mutating func loadCards() throws -> [String] {
        var errors: [String] = []
        let modulesFolder = appRoot.appendingPathComponent("Modules", isDirectory: true)
        let folders = try FileManager.default.contentsOfDirectory(
            at: modulesFolder, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for folder in folders {
            let cardFile = folder.appendingPathComponent("module.yaml")
            let relative = "Modules/\(folder.lastPathComponent)/module.yaml"
            guard FileManager.default.fileExists(atPath: cardFile.path) else {
                errors.append("Modules/\(folder.lastPathComponent): folder has no module.yaml")
                continue
            }
            do {
                let text = try String(contentsOf: cardFile, encoding: .utf8)
                var card = try YAMLDecoder().decode(ModuleCard.self, from: text)
                card.relativePath = relative
                if card.id != folder.lastPathComponent {
                    errors.append("\(relative): id '\(card.id)' does not match its folder name")
                }
                cards[card.id] = card
            } catch {
                errors.append("\(relative): \(error)")
            }
        }
        if cards.isEmpty {
            errors.append("no module cards found under Modules/")
        }
        return errors
    }

    // MARK: Card rules

    func checkCards() -> [String] {
        var errors: [String] = []
        for card in cards.values.sorted(by: { $0.id < $1.id }) {
            let whereText = card.relativePath
            let fields: [(String, String, Set<String>)] = [
                ("kind", card.kind, ModuleRules.kinds),
                ("runs_in", card.runsIn, ModuleRules.runsIn),
                ("status", card.status, ModuleRules.statuses),
                ("default", card.defaultState, ModuleRules.defaults)
            ]
            for (name, value, allowed) in fields where !allowed.contains(value) {
                errors.append("\(whereText): \(name) must be one of \(allowed.sorted()), got '\(value)'")
            }
            if card.summary.isEmpty {
                errors.append("\(whereText): summary is missing")
            }
            let allowed = ModuleRules.allowedDependencyKinds[card.kind] ?? []
            for dependency in card.dependencies {
                guard let target = cards[dependency] else {
                    errors.append("\(whereText): depends_on names unknown module '\(dependency)'")
                    continue
                }
                if !allowed.contains(target.kind) {
                    errors.append("\(whereText): a \(card.kind) module may not depend on "
                        + "'\(dependency)' (\(target.kind))")
                }
            }
        }
        return errors + findCycles()
    }

    private func findCycles() -> [String] {
        enum Mark { case active, done }
        var marks: [String: Mark] = [:]
        var errors: [String] = []

        func visit(_ id: String, trail: [String]) {
            switch marks[id] {
            case .done: return
            case .active:
                if let start = trail.firstIndex(of: id) {
                    errors.append("dependency cycle: " + (trail[start...] + [id]).joined(separator: " -> "))
                }
                return
            case nil: break
            }
            marks[id] = .active
            for dependency in cards[id]?.dependencies ?? [] where cards[dependency] != nil {
                visit(dependency, trail: trail + [id])
            }
            marks[id] = .done
        }

        for id in cards.keys.sorted() {
            visit(id, trail: [])
        }
        return errors
    }

    // MARK: Ownership

    /// Every upstream source file must be owned by exactly one card (§1.5 rule 1).
    mutating func checkOwnership() throws -> [String] {
        var errors: [String] = []
        let files = sourceFiles(under: Self.upstreamRoots)
        owners = Dictionary(uniqueKeysWithValues: files.map { ($0, [String]()) })

        for card in cards.values.sorted(by: { $0.id < $1.id }) {
            let includes = try card.ownedPaths.map(Glob.init)
            let excludes = try card.excludedPaths.map(Glob.init)
            for glob in includes where !files.contains(where: glob.matches) {
                errors.append("\(card.relativePath): path '\(glob.pattern)' matches no source file")
            }
            for file in files where includes.contains(where: { $0.matches(file) })
                && !excludes.contains(where: { $0.matches(file) }) {
                owners[file, default: []].append(card.id)
            }
            for split in card.splits {
                let exists = FileManager.default.fileExists(
                    atPath: repositoryRoot.appendingPathComponent(split.file).path)
                if !exists {
                    errors.append("\(card.relativePath): pending_splits file '\(split.file)' does not exist")
                }
                if cards[split.to] == nil {
                    errors.append("\(card.relativePath): pending_splits target '\(split.to)' is not a module")
                }
            }
        }

        for (file, who) in owners.sorted(by: { $0.key < $1.key }) {
            if who.isEmpty {
                errors.append("unowned source file: \(file)")
            } else if who.count > 1 {
                errors.append("source file owned by several modules (\(who.joined(separator: ", "))): \(file)")
            }
        }
        return errors
    }

    /// New app code lives in `Modules/<id>/`; that folder's card owns it.
    /// A code folder without a card is an error.
    func checkNewCodeFolders() -> [String] {
        var errors: [String] = []
        for file in sourceFiles(under: ["Modules"]) {
            let parts = file.split(separator: "/")
            guard parts.count > 2 else { continue }
            let moduleID = String(parts[1])
            if cards[moduleID] == nil {
                errors.append("new code outside a module with a card: \(file)")
            }
        }
        return errors
    }

    /// The language rule: Swift, Objective-C and C++ only (PLAN.md, Target platform).
    func checkLanguages() -> [String] {
        let skipped = ["Host/", "Runtime/", "Vendor/", ".build/"]
        return allFiles()
            .filter { file in !skipped.contains(where: file.hasPrefix) }
            .filter { Self.forbiddenExtensions.contains(($0 as NSString).pathExtension) }
            .map { "language rule: \($0) is not Swift, Objective-C or C++" }
    }

    // MARK: MODULES.md

    func renderModulesFile() -> String {
        var counts: [String: Int] = [:]
        for (_, who) in owners where who.count == 1 {
            counts[who[0], default: 0] += 1
        }
        var lines = [
            "# Modules",
            "",
            "Generated by `swift run mulg-modules write` from `Modules/*/module.yaml`. Do not edit by hand.",
            "",
            "| Module | Kind | Runs in | Status | Default | Depends on | Files | Summary |",
            "|---|---|---|---|---|---|---|---|"
        ]
        let sorted = cards.values.sorted { $0.id < $1.id }
        for card in sorted {
            let dependencies = card.dependencies.isEmpty
                ? "—" : card.dependencies.map { "`\($0)`" }.joined(separator: ", ")
            lines.append("| [`\(card.id)`](\(card.relativePath)) | \(card.kind) | \(card.runsIn) | "
                + "\(card.status) | \(card.defaultState) | \(dependencies) | \(counts[card.id] ?? 0) | \(card.summary) |")
        }
        let splits = sorted.flatMap { card in card.splits.map { (card.id, $0) } }
        if !splits.isEmpty {
            lines += ["", "## Pending splits", "",
                      "Code that sits in one module's file today but belongs to another (PLAN.md §1.6).", "",
                      "| File | Owned by | Move | To |", "|---|---|---|---|"]
            for (id, split) in splits {
                lines.append("| `\(split.file)` | `\(id)` | \(split.move) | `\(split.to)` |")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Module status for the app

    /// Where the app's copy of each card's `status` lives: the cards stay in the repository,
    /// so the Modules page reads this generated file instead.
    var statusFile: URL {
        appRoot.appendingPathComponent("Modules/gui/Sources/MulgGUI/ModuleStatus.generated.swift")
    }

    /// A switch over `ModuleID`, so a card without a case, or a case without a card, fails to
    /// compile.
    func renderStatusFile() -> String {
        var lines = [
            "// Generated by `swift run mulg-modules write` from `Modules/*/module.yaml`. Do not edit by hand.",
            "import MulgContracts",
            "",
            "extension ModuleID {",
            "    /// The module card's `status`: stable, experimental or planned (PLAN.md §1.4).",
            "    public var cardStatus: String {",
            "        switch self {"
        ]
        for card in cards.values.sorted(by: { $0.id < $1.id }) {
            let parts = card.id.split(separator: "-")
            let identifier = (parts.first.map(String.init) ?? card.id)
                + parts.dropFirst().map { $0.prefix(1).uppercased() + String($0.dropFirst()) }.joined()
            lines.append("        case .\(identifier): \"\(card.status)\"")
        }
        lines += ["        }", "    }", "}"]
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Files

    private func sourceFiles(under roots: [String]) -> [String] {
        roots.flatMap { root in
            files(in: repositoryRoot.appendingPathComponent(root, isDirectory: true))
                .filter { Self.sourceExtensions.contains(($0 as NSString).pathExtension) }
        }.sorted()
    }

    private func allFiles() -> [String] {
        files(in: repositoryRoot).sorted()
    }

    /// Regular files under `folder`, excluding repository metadata and generated build products.
    private func files(in folder: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        let rootPath = repositoryRoot.standardizedFileURL.path + "/"
        var result: [String] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == ".git" || url.lastPathComponent == ".build"
                || url.standardizedFileURL.path == repositoryRoot.appendingPathComponent("Host/RuntimeBuild").path {
                enumerator.skipDescendants()
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            let path = url.standardizedFileURL.path
            if path.hasPrefix(rootPath) {
                result.append(String(path.dropFirst(rootPath.count)))
            }
        }
        return result
    }
}
