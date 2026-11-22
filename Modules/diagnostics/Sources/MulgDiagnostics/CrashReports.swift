import Foundation
import MachO
import MulgContracts
import MulgDiagnosticsHooks
import MulgEngine
import os

/// Crash reports (PLAN.md §8.3). A crash writes `Crash-<unix time>-<pid>.txt` to the game's diagnostics
/// folder, which "Export diagnostics" already puts in the zip. Nothing is written while the game
/// runs normally; this code only keeps the text the report ends with up to date.
extension DiagnosticsModule {
    /// Reports kept; older ones are removed at launch.
    nonisolated static let keptCrashReports = 10
    /// Versions and settings, set once at launch; module states are added after start.
    private static var crashHeader = ""
    /// Freeze reports, on together with crash reports.
    nonisolated static let hangWatchdog = HangWatchdog()
    /// The signal and exception handlers are installed; `applyDebugging` switches them live.
    static var crashReporterActive = false
    private static var crashStage = ""
    private static var crashNotes: [ModuleID: String] = [:]

    /// The runtime calls this before any module prepares, so a crash while they start is reported too.
    public static func installCrashReporter(settings: GameSettings, paths: ContainerPaths, bundleIdentifier: String) {
        guard settings.mulg.engine.isModuleEnabled(.diagnostics), settings.mulg.diagnostics.writesCrashReports else {
            return
        }
        let directory = paths.diagnosticsDirectory(for: bundleIdentifier)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            MulgLog.logger(.diagnostics).error("No crash reports: \(error.localizedDescription, privacy: .public)")
            return
        }
        removeOldCrashReports(in: directory)

        var sanitized = settings
        sanitized.discordActivity = DiscordActivitySettings()  // account data, as in DiagnosticsExport
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = (try? encoder.encode(sanitized)).map { String(decoding: $0, as: UTF8.self) } ?? "(not encodable)"
        let info = Bundle.main.infoDictionary ?? [:]
        let process = ProcessInfo.processInfo
        crashHeader = """
            Mulg \(MulgVersion.current), runtime protocol \(MulgVersion.runtimeProtocol)
            Game: \(bundleIdentifier) \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))
            System: \(process.operatingSystemVersionString), \(process.physicalMemory >> 30) GB, \(process.activeProcessorCount) cores
            Settings: \(json)
            """
        setCrashContext("Stage: modules starting (a crash here is in Mulg's start-up or a module's prepare)")
        directory.path.withCString { mulg_crash_install($0) }
        mulg_hang_watch_main_thread()
        hangWatchdog.start(directory: directory)
        crashReporterActive = true
    }

    /// After start: which modules run and which hooks are missing.
    func updateCrashContext(reports: [ModuleReport]) {
        guard let context else { return }
        Self.setCrashContext("""
            Stage: running\(context.launch.isSafe ? " in safe mode" : "")
            \(moduleStates(reports: reports, context: context))
            """)
    }

    /// The crash report's and the debugger's list of modules and missing hooks.
    func moduleStates(reports: [ModuleReport], context: ModuleContext) -> String {
        context.hooks.refreshInstallationReports()
        let modules = reports.map { "  \($0.id.rawValue): \(String(describing: $0.state))" }
        let missing = context.hooks.missing.map { "  \($0.target) (\($0.owner.rawValue))" }
        let conflicts = context.hooks.conflicts.map { "  \($0.target) (\($0.owner.rawValue))" }
        return """
            Modules:
            \(modules.joined(separator: "\n"))
            Hooks installed: \(context.hooks.entries.count), missing: \(missing.isEmpty ? "none" : "\n" + missing.joined(separator: "\n"))
            Hooks rejected for ownership conflict: \(conflicts.isEmpty ? "none" : "\n" + conflicts.joined(separator: "\n"))
            """
    }

    /// The stage text, the modules' notes (`DiagnosticNote`) and the launch header, as every
    /// crash and freeze report ends.
    static func setCrashContext(_ stage: String) {
        crashStage = stage
        let notes = crashNotes.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue):\n\($0.value)\n" }
        (stage + "\n" + notes.joined() + crashHeader).withCString { mulg_crash_set_context($0) }
    }

    static func noteForCrashReports(_ note: DiagnosticNote) {
        crashNotes[note.module] = note.text.isEmpty ? nil : note.text
        if crashReporterActive { setCrashContext(crashStage) }
    }

    /// The names hold the Unix time with the same number of digits, so name order is age order.
    nonisolated static func removeOldCrashReports(in directory: URL, prefix: String = "Crash-") {
        let files = FileManager.default
        let reports = ((try? files.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".txt") }
            .sorted()
        for name in reports.dropLast(keptCrashReports) {
            try? files.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}

/// Crash recovery (PLAN.md §8.3): at the next launch the newest report is read once. When the
/// first frame outside Apple's libraries is Mulg's own code, the module that code belongs to is
/// named, so the runtime can switch it off for this game.
extension DiagnosticsModule {
    /// The newest crash or unrecovered freeze report not read before (its file name), the module it
    /// blames, and whether it was a freeze. Nil without a new report. The module is nil when the game,
    /// a plug-in or Apple's code crashed or froze, the code cannot be tied to a module, or the report
    /// came from another build of the runtime. A freeze blames the main thread's code only.
    public static func lastCrash(settings: GameSettings, paths: ContainerPaths,
                                 bundleIdentifier: String) -> (report: String, module: ModuleID?, hang: Bool)? {
        guard settings.mulg.engine.isModuleEnabled(.diagnostics), settings.mulg.diagnostics.writesCrashReports else {
            return nil
        }
        let directory = paths.diagnosticsDirectory(for: bundleIdentifier)
        let checked = directory.appendingPathComponent("crash-checked.txt")
        let reports = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { isRecoveryReport($0) }
        guard let newest = reports.max(by: { reportTime($0) < reportTime($1) }),
              (try? String(contentsOf: checked, encoding: .utf8)) != newest else { return nil }
        try? newest.writeBeside(to: checked)
        let hang = newest.hasPrefix("Hang-")
        guard let report = try? String(contentsOf: directory.appendingPathComponent(newest), encoding: .utf8),
              let runtime = imageUUID(#dsohandle) else { return (newest, nil, hang) }
        let module = blamedModule(report: report, runtimeUUID: runtime,
                                  thread: hang ? "Backtrace of the hung main thread" : "Backtrace of the crashed thread") { offset in
            var info = Dl_info()
            guard dladdr(#dsohandle.advanced(by: Int(offset)), &info) != 0, let name = info.dli_sname else { return nil }
            return String(cString: name)
        }
        return (newest, module, hang)
    }

    /// Crash reports, and freeze reports whose main thread never answered again.
    static func isRecoveryReport(_ name: String) -> Bool {
        name.hasSuffix(".txt") && (name.hasPrefix("Crash-") || (name.hasPrefix("Hang-") && !name.hasSuffix("-recovered.txt")))
    }

    /// The Unix time in "Crash-<time>.txt" or "Hang-<time>.txt".
    static func reportTime(_ name: String) -> Int {
        Int(name.drop { !$0.isNumber }.prefix { $0.isNumber }) ?? 0
    }

    /// Reads the report's backtrace. `symbol` names the code at an offset into this runtime.
    // ponytail: only Swift symbols and `mulg_<module>_` C functions name a module; static hook
    // functions in the Objective-C files do not, so a crash inside one blames nothing.
    static func blamedModule(report: String, runtimeUUID: String, thread: String = "Backtrace of the crashed thread",
                             symbol: (UInt64) -> String?) -> ModuleID? {
        let lines = report.components(separatedBy: "\n")
        // "0x104a2c000  <UUID>  <path>", keyed by file name, as the backtrace names images.
        var images: [String: (uuid: String, path: String)] = [:]
        if let start = lines.firstIndex(where: { $0.hasPrefix("Images in the backtrace") }) {
            for line in lines[(start + 1)...] {
                let parts = line.components(separatedBy: "  ")
                guard parts.count >= 3 else { break }
                let path = parts[2...].joined(separator: "  ")
                images[(path as NSString).lastPathComponent] = (parts[1], path)
            }
        }
        guard let start = lines.firstIndex(of: thread) else { return nil }
        // "3  0x104a3f10c  MulgRuntime + 0x1310c"
        for line in lines[(start + 1)...] {
            let parts = line.components(separatedBy: "  ")
            guard let index = Int(parts[0]) else { break }
            guard parts.count >= 3, let plus = parts[2].range(of: " + 0x", options: .backwards),
                  let image = images[String(parts[2][..<plus.lowerBound])],
                  let offset = UInt64(parts[2][plus.upperBound...], radix: 16) else { continue }
            if image.path.hasPrefix("/usr/lib/") || image.path.hasPrefix("/System/") { continue }
            // Callers' frames hold return addresses, one instruction past the call.
            guard image.uuid == runtimeUUID, let name = symbol(index == 0 || offset == 0 ? offset : offset - 1) else { return nil }
            return module(forSymbol: name)
        }
        return nil
    }

    /// "$s11MulgDisplay…" and "mulg_display_…" name the display module.
    static func module(forSymbol symbol: String) -> ModuleID? {
        if symbol.hasPrefix("mulg_") {
            return ModuleID(rawValue: String(symbol.dropFirst(5).prefix { $0 != "_" }))
        }
        // dladdr may keep the linker's leading underscore.
        let body = symbol.hasPrefix("_") ? symbol.dropFirst() : Substring(symbol)
        guard body.hasPrefix("$s") else { return nil }
        let rest = body.dropFirst(2)
        let digits = rest.prefix(while: \.isNumber)
        guard let length = Int(digits) else { return nil }
        let name = rest.dropFirst(digits.count).prefix(length)
        guard name.hasPrefix("Mulg") else { return nil }
        var id = name.dropFirst(4).lowercased()
        if id.hasSuffix("hooks") { id.removeLast(5) }
        return ModuleID(rawValue: id)
    }

    /// The LC_UUID of the image whose Mach-O header is at `header`, as the report writes it.
    static func imageUUID(_ header: UnsafeRawPointer) -> String? {
        var command = header + MemoryLayout<mach_header_64>.size
        for _ in 0..<header.load(as: mach_header_64.self).ncmds {
            let load = command.load(as: load_command.self)
            if load.cmd == UInt32(LC_UUID) {
                return UUID(uuid: command.load(as: uuid_command.self).uuid).uuidString
                    .replacingOccurrences(of: "-", with: "")
            }
            command += Int(load.cmdsize)
        }
        return nil
    }
}
