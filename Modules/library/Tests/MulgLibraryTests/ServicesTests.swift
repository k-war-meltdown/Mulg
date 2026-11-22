// Host-side module: the Mulg app is a native macOS app, never Mac Catalyst.
#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import MulgContracts
import Testing
@testable import MulgLibrary

func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mulg-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

@Suite struct MulgSignTests {
    @Test func commandsKeepTheUsersOwnBootArguments() {
        #expect(MulgSign.enableCommand(currentBootArguments: "")
                == "sudo /usr/sbin/nvram boot-args='amfi_get_out_of_my_way=0x1 ipc_control_port_options=0'")
        #expect(MulgSign.enableCommand(currentBootArguments: "-v amfi_get_out_of_my_way=1")
                == "sudo /usr/sbin/nvram boot-args='-v amfi_get_out_of_my_way=0x1 ipc_control_port_options=0'")
        #expect(MulgSign.disableCommand(currentBootArguments: "amfi_get_out_of_my_way=0x1 ipc_control_port_options=0")
                == "sudo /usr/sbin/nvram -d boot-args")
        #expect(MulgSign.disableCommand(currentBootArguments: "-v amfi_get_out_of_my_way=0x1")
                == "sudo /usr/sbin/nvram boot-args='-v'")
        #expect(MulgSign.enableCommand(currentBootArguments: "-v $(touch /tmp/unsafe)")
                == "sudo /usr/sbin/nvram boot-args='-v $(touch /tmp/unsafe) amfi_get_out_of_my_way=0x1 ipc_control_port_options=0'")
        #expect(MulgSign.disableCommand(currentBootArguments: "-v foo'bar")
                == "sudo /usr/sbin/nvram boot-args='-v foo'\\''bar'")
    }

    @Test func detectsState() {
        #expect(MulgSign.isActive(kernelBootArguments: "-v amfi_get_out_of_my_way=0x1"))
        #expect(!MulgSign.isActive(kernelBootArguments: "amfi_get_out_of_my_way=0"))
        #expect(MulgSign.isSIPDisabled(csrutilStatus: "System Integrity Protection status: disabled."))
        #expect(!MulgSign.isSIPDisabled(csrutilStatus: "System Integrity Protection status: enabled."))
    }
}

@Suite struct GameWatcherTests {
    @Test func turnsWorkspaceNotificationsIntoEvents() async {
        let center = NotificationCenter()
        let stream = GameWatcher.events(center: center)
        let app = NSRunningApplication.current
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: app])
        var events = stream.makeAsyncIterator()
        #expect(await events.next() == GameWatcher.Event(bundleIdentifier: app.bundleIdentifier,
                                                         processIdentifier: app.processIdentifier, launched: false))
    }
}

@Suite struct SaveBackupTests {
    private func settings(_ label: String) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["label": label], format: .xml, options: 0)
    }

    @Test func malformedLaterPartCannotReplaceDataAndHeldSessionRejectsRestore() throws {
        let root = try temporaryFolder(), files = FileManager.default
        defer { try? files.removeItem(at: root) }
        let paths = ContainerPaths(home: root), id = "audit.restore"
        let data = paths.gameContainer(for: id).appendingPathComponent("Data")
        try files.createDirectory(at: data, withIntermediateDirectories: true)
        try files.createDirectory(at: paths.appSettingsDirectory, withIntermediateDirectories: true)
        try Data("backup".utf8).write(to: data.appendingPathComponent("save"))
        try settings("backup").write(to: paths.settingsFile(for: id))
        let backup = SaveBackup(folder: root.appendingPathComponent("backups"), paths: paths)
        let version = try backup.backUp(id, date: Date(timeIntervalSince1970: 0))
        try Data("current".utf8).write(to: data.appendingPathComponent("save"))
        try settings("current").write(to: paths.settingsFile(for: id))
        try Data("invalid plist".utf8).write(to: version.appendingPathComponent("Settings.plist"))
        #expect(throws: (any Error).self) { try backup.restore(version, bundleIdentifier: id) }
        #expect(try String(contentsOf: data.appendingPathComponent("save"), encoding: .utf8) == "current")
        #expect(try Data(contentsOf: paths.settingsFile(for: id)) == settings("current"))
        let lease = try GameSessionLease(bundleIdentifier: id, paths: paths)
        defer { withExtendedLifetime(lease) {} }
        #expect(throws: GameSessionLease.Failure.busy) { try backup.restore(version, bundleIdentifier: id) }
        #expect(throws: GameSessionLease.Failure.busy) { try backup.backUp(id) }
    }

    @Test(arguments: 0...7) func interruptedRestoreRecoversEveryPart(_ completedSteps: Int) throws {
        let root = try temporaryFolder(), files = FileManager.default
        defer { try? files.removeItem(at: root) }
        let paths = ContainerPaths(home: root), id = "audit.recover"
        var items: [SaveBackup.RestoreItem] = []
        for target in try SaveBackup.destinations(id, paths) {
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staged = target.deletingLastPathComponent().appendingPathComponent(".mulg-restore-stage-test")
            let old = target.deletingLastPathComponent().appendingPathComponent(".mulg-restore-backup-test")
            try Data("old".utf8).write(to: target)
            try Data("new".utf8).write(to: staged)
            items.append(.init(target: target, staged: staged, backup: old, hadTarget: true))
        }
        try SaveBackup.save(.init(items: items, committed: false), id, paths)
        for (index, item) in items.enumerated() {
            if completedSteps > index * 2 { try BundleTransaction.move(item.target, item.backup) }
            if completedSteps > index * 2 + 1 { try BundleTransaction.move(item.staged, item.target) }
        }
        let committed = completedSteps == 7
        if committed { try SaveBackup.save(.init(items: items, committed: true), id, paths) }
        let lease = try GameSessionLease(bundleIdentifier: id, paths: paths)
        defer { withExtendedLifetime(lease) {} }
        try SettingsStore(paths: paths).withExclusiveAccess(bundleIdentifier: id) {
            try SaveBackup.recover(id, paths: paths)
            try SaveBackup.recover(id, paths: paths)
        }
        for item in items {
            #expect(try String(contentsOf: item.target, encoding: .utf8) == (committed ? "new" : "old"))
            #expect(!files.fileExists(atPath: item.backup.path))
            #expect(!files.fileExists(atPath: item.staged.path))
        }
    }
    @Test func failedSettingsRestoreKeepsCurrentSettings() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ContainerPaths(home: root.appendingPathComponent("home"))
        let game = "com.example.game"
        let current = paths.settingsFile(for: game)
        try FileManager.default.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("current".utf8).write(to: current)
        let version = root.appendingPathComponent("broken-backup", isDirectory: true)
        try FileManager.default.createDirectory(at: version.appendingPathComponent("Settings.plist"),
                                                withIntermediateDirectories: true)
        let backup = SaveBackup(folder: root.appendingPathComponent("backups"), paths: paths)

        #expect(throws: (any Error).self) { try backup.restore(version, bundleIdentifier: game) }
        #expect(try String(contentsOf: current, encoding: .utf8) == "current")
    }

    @Test func backsUpAndRestoresWithASafetyVersion() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ContainerPaths(home: root.appendingPathComponent("home"))
        let game = "com.example.game"
        let files = FileManager.default
        let data = paths.gameContainer(for: game).appendingPathComponent("Data/Documents", isDirectory: true)
        try files.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("level 3".utf8).write(to: data.appendingPathComponent("save"))
        try files.createDirectory(at: paths.appSettingsDirectory, withIntermediateDirectories: true)
        try settings("settings v1").write(to: paths.settingsFile(for: game))

        let backup = SaveBackup(folder: root.appendingPathComponent("iCloud"), paths: paths)
        let version = try backup.backUp(game, date: Date(timeIntervalSince1970: 0))
        #expect(version.lastPathComponent == "1970-01-01_00-00-00")
        #expect(throws: CocoaError.self) { try backup.backUp(game, date: Date(timeIntervalSince1970: 0)) }

        try Data("level 9".utf8).write(to: data.appendingPathComponent("save"))
        try Data("new file".utf8).write(to: data.appendingPathComponent("extra"))
        try settings("settings v2").write(to: paths.settingsFile(for: game))

        let safety = try backup.restore(version, bundleIdentifier: game)
        #expect(try String(contentsOf: data.appendingPathComponent("save"), encoding: .utf8) == "level 3")
        #expect(!files.fileExists(atPath: data.appendingPathComponent("extra").path))
        #expect(try Data(contentsOf: paths.settingsFile(for: game)) == settings("settings v1"))
        #expect(backup.versions(of: game) == [safety, version])

        // A folder that is not a version is refused before anything changes.
        #expect(throws: SaveBackup.Failure.self) { try backup.restore(root, bundleIdentifier: game) }
        // Restoring a backup made this same second still gets its own safety version.
        let fresh = try backup.backUp(game)
        #expect(try backup.restore(fresh, bundleIdentifier: game) != fresh)
    }
}

@Suite struct DiagnosticsExportTests {
    @Test func zipHoldsSanitizedSettingsAndSummary() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = GameSettings(bundleIdentifier: "com.example.game")
        settings.discordActivity.applicationID = "secret"
        settings.mulg.engine.environment = ["GAME_API_TOKEN": "abc123"]
        settings.mulg.engine.disabledModules = ["graphics"]
        let archive = root.appendingPathComponent("report.zip")
        try DiagnosticsExport.export(settings, to: archive, paths: ContainerPaths(home: root),
                                     mac: MacInfo(model: "Mac17,1", systemVersion: "27.0"), logs: { "log line" })

        try Command.run("/usr/bin/ditto", ["-x", "-k", archive.path, root.path])
        let folder = root.appendingPathComponent("com.example.game diagnostics")
        let saved = try SettingsStore.decode(Data(contentsOf: folder.appendingPathComponent("Settings.plist")))
        #expect(saved.discordActivity.applicationID.isEmpty)
        #expect(saved.mulg.engine.environment == ["GAME_API_TOKEN": "<removed>"])  // the name stays, the value never leaves
        let summary = try String(contentsOf: folder.appendingPathComponent("Summary.txt"), encoding: .utf8)
        #expect(summary.contains("Mac17,1, macOS 27.0") && summary.contains("graphics: off"))
        #expect(try String(contentsOf: folder.appendingPathComponent("Logs.txt"), encoding: .utf8) == "log line")
    }
}

@Suite struct RuntimeInstallerTests {
    @Test func replacesTheInstalledFramework() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root.appendingPathComponent("MulgRuntime.framework", isDirectory: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        let home = root.appendingPathComponent("home")
        let installed = URL(fileURLWithPath: GameInstaller.runtimePath(home: home))

        for version in ["1", "2"] {
            try Data(version.utf8).write(to: bundled.appendingPathComponent("MulgRuntime"))
            try RuntimeInstaller.install(bundled: bundled, home: home)
            #expect(try String(contentsOf: installed, encoding: .utf8) == version)
        }
        // A copy that fails keeps the working framework and leaves no staging folder.
        let missing = root.appendingPathComponent("Missing.framework")
        #expect(throws: (any Error).self) { try RuntimeInstaller.install(bundled: missing, home: home) }
        #expect(try String(contentsOf: installed, encoding: .utf8) == "2")
        #expect(try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent()
            .deletingLastPathComponent().path) == ["MulgRuntime.framework"])
    }
}

@Suite struct RestorePreviewTests {
    @Test func previewShowsDateAndWhatIsReplaced() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let version = root.appendingPathComponent("2026-09-28_10-30-00", isDirectory: true)
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        try Data("12345".utf8).write(to: version.appendingPathComponent("Data.zip"))
        try Data("s".utf8).write(to: version.appendingPathComponent("Settings.plist"))

        let preview = try #require(SaveBackup.preview(of: version))
        #expect(preview.items == [.init(part: .gameData, bytes: 5), .init(part: .settings, bytes: 1)])
        #expect(preview.date == Date(timeIntervalSince1970: 1_790_591_400))
        #expect(SaveBackup.preview(of: root) == nil)
    }

    @Test func cancellingBeforeAnythingIsReplacedKeepsTheSaves() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ContainerPaths(home: root.appendingPathComponent("home"))
        let game = "com.example.game"
        try FileManager.default.createDirectory(at: paths.appSettingsDirectory, withIntermediateDirectories: true)
        try Data("current".utf8).write(to: paths.settingsFile(for: game))
        let backup = SaveBackup(folder: root.appendingPathComponent("backups"), paths: paths)
        let version = try backup.backUp(game, date: Date(timeIntervalSince1970: 0))

        let task = Task.detached { () throws -> URL in
            withUnsafeCurrentTask { $0?.cancel() }
            return try backup.restore(version, bundleIdentifier: game)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try String(contentsOf: paths.settingsFile(for: game), encoding: .utf8) == "current")
        #expect(backup.versions(of: game) == [version])
    }
}
#endif
