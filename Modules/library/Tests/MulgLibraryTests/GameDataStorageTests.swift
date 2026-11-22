import Foundation
import Testing
import MulgContracts
@testable import MulgLibrary

@Suite("Support folders and full game removal")
struct GameDataStorageTests {
    let files = FileManager.default
    func fixture(_ home: URL, id: String) throws -> URL {
        let app = home.appendingPathComponent("External/" + id + ".app")
        try files.createDirectory(at: app, withIntermediateDirectories: true)
        try files.createDirectory(at: ContainerPaths(home: home).gameContainer(for: id).appendingPathComponent("Data"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        return app
    }

    @Test func inventoryChecksEverySiblingAfterLinksAndDetectsChangedBytes() throws {
        let source = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // Set this for the real SMB regression; generated files only, never game data.
        let parent = ProcessInfo.processInfo.environment["MULG_STORAGE_TEST_NETWORK_PARENT"]
            .map { URL(fileURLWithPath: $0) } ?? files.temporaryDirectory
        let target = parent.appendingPathComponent(".mulg-inventory-" + UUID().uuidString)
        defer { try? files.removeItem(at: source); try? files.removeItem(at: target) }
        try files.createDirectory(at: source, withIntermediateDirectories: true)
        for name in ["Application Support", "Caches", "Preferences"] {
            let directory = source.appendingPathComponent(name)
            try files.createDirectory(at: directory.appendingPathComponent("nested"), withIntermediateDirectories: true)
            try Data("synthetic asset".utf8).write(to: directory.appendingPathComponent("nested/asset"))
        }
        try files.createSymbolicLink(atPath: source.appendingPathComponent("Audio").path, withDestinationPath: "../../../../Audio")
        try files.createSymbolicLink(atPath: source.appendingPathComponent("PreferencesLink").path, withDestinationPath: "Application Support")
        try BundleTransaction.copy(source, to: target)
        let original = try GameDataStorage.inventory(source)
        #expect(original.count == 11)
        #expect(try GameDataStorage.inventory(target) == original)
        try Data("changed asset".utf8).write(to: target.appendingPathComponent("Application Support/nested/asset"))
        #expect(try GameDataStorage.inventory(target) != original)
        #expect(try String(contentsOf: source.appendingPathComponent("Application Support/nested/asset"), encoding: .utf8) == "synthetic asset")
    }

    @Test func foldersCreatedLaterInTheLocalLibraryMoveToTheGameFolder() throws {
        let root = files.temporaryDirectory.appendingPathComponent("mulg-sweep-" + UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let local = root.appendingPathComponent("Container/Data/Library"), external = root.appendingPathComponent("Game/Data/Library")
        for name in ["Preferences", "Cookies", "DownloadedPacks/nested", "Caches/sdk"] {
            try files.createDirectory(at: local.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("pack".utf8).write(to: local.appendingPathComponent("DownloadedPacks/nested/pack.bin"))
        try Data("cache".utf8).write(to: local.appendingPathComponent("Caches/sdk/c"))
        try Data("prefs".utf8).write(to: local.appendingPathComponent("Preferences/p.plist"))
        // The runtime's empty placeholder gives way; a non-empty external folder is never merged into.
        try files.createDirectory(at: external.appendingPathComponent("Caches"), withIntermediateDirectories: true)
        try files.createDirectory(at: local.appendingPathComponent("Busy"), withIntermediateDirectories: true)
        try files.createDirectory(at: external.appendingPathComponent("Busy"), withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: external.appendingPathComponent("Busy/k"))

        let moved = try GameDataStorage.sweepLocalLibrary(local, external: external)
        #expect(Set(moved) == ["DownloadedPacks", "Caches"])
        #expect(try String(contentsOf: external.appendingPathComponent("DownloadedPacks/nested/pack.bin"), encoding: .utf8) == "pack")
        #expect(try String(contentsOf: external.appendingPathComponent("Caches/sdk/c"), encoding: .utf8) == "cache")
        // The game still finds them at the old place, through links.
        #expect(try files.destinationOfSymbolicLink(atPath: local.appendingPathComponent("DownloadedPacks").path) == external.appendingPathComponent("DownloadedPacks").path)
        #expect(try String(contentsOf: local.appendingPathComponent("Caches/sdk/c"), encoding: .utf8) == "cache")
        // macOS-owned folders and the conflicting one stay local and untouched.
        for name in ["Preferences", "Cookies", "Busy"] {
            #expect((try local.appendingPathComponent(name).resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true)
        }
        #expect(try String(contentsOf: external.appendingPathComponent("Busy/k"), encoding: .utf8) == "kept")
        #expect(try GameDataStorage.sweepLocalLibrary(local, external: external).isEmpty)  // nothing twice
    }

    @Test func freshInstallAndFutureDownloadsUseSupportFolderAndKeepHomeLinks() throws {
        let home = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: home) }
        let id = "audit.storage", paths = ContainerPaths(home: home), app = try fixture(home, id: id)
        let data = paths.gameContainer(for: id).appendingPathComponent("Data")
        try files.createDirectory(at: data.appendingPathComponent("Library/MihoyoDownload/Persistent"), withIntermediateDirectories: true)
        let old = data.appendingPathComponent("Library/MihoyoDownload/Persistent/asset")
        try Data("downloaded game bytes".utf8).write(to: old)
        try files.createSymbolicLink(atPath: data.appendingPathComponent("Downloads").path, withDestinationPath: "../../../../Downloads")
        let root = try GameDataStorage.prepare(for: app, bundleIdentifier: id, paths: paths)
        #expect(try String(contentsOf: old, encoding: .utf8) == "downloaded game bytes")
        try Data("next in-game update".utf8).write(to: root.appendingPathComponent("Data/Library/new-update"))
        #expect(try String(contentsOf: root.appendingPathComponent("Data/Library/new-update"), encoding: .utf8) == "next in-game update")
        #expect(try files.destinationOfSymbolicLink(atPath: data.appendingPathComponent("Downloads").path) == "../../../../Downloads")
        #expect(files.fileExists(atPath: paths.gameContainer(for: id).appendingPathComponent("MulgDataBackup").path))
        #expect(try GameDataStorage.prepare(for: app, bundleIdentifier: id, paths: paths) == root)
    }

    @Test func newGameGetsEveryStandardDataDirectoryBeforeItRuns() throws {
        let home = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: home) }
        let id = "audit.fresh", paths = ContainerPaths(home: home), app = try fixture(home, id: id)
        try files.removeItem(at: paths.gameContainer(for: id))
        let root = try GameDataStorage.prepare(for: app, bundleIdentifier: id, paths: paths)
        for name in GameDataStorage.names {
            #expect(files.fileExists(atPath: root.appendingPathComponent("Data/" + name).path))
        }
        #expect(!files.fileExists(atPath: paths.gameContainer(for: id).path))
    }

    @Test @MainActor func preparedStorageReleasesItsLeaseBeforeRuntimeHandoff() async throws {
        let home = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: home) }
        let id = "audit.handoff", paths = ContainerPaths(home: home), app = try fixture(home, id: id)
        var host: GameSessionLease? = try GameSessionLease(bundleIdentifier: id, paths: paths)
        let root = try await GameDataStorage.prepareForLaunch(for: app, bundleIdentifier: id, paths: paths, sessionLease: host)
        let reservation = try #require(host).reserveLaunch()
        host = nil
        #expect(throws: GameSessionLease.Failure.busy) { try GameSessionLease(bundleIdentifier: id, paths: paths) }
        let runtime = try GameSessionLease(bundleIdentifier: id, paths: paths, launchToken: reservation.token)
        #expect(reservation.isClaimed)
        #expect(files.fileExists(atPath: root.appendingPathComponent("Data/Library").path))
        withExtendedLifetime((reservation, runtime)) {}
    }

    @Test func reinstallRepairsDanglingOwnedDocumentsLinkAndKeepsExistingLibrary() throws {
        let home = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let networkParent = ProcessInfo.processInfo.environment["MULG_STORAGE_TEST_NETWORK_PARENT"]
            .map { URL(fileURLWithPath: $0) } ?? home
        let install = networkParent.appendingPathComponent(".mulg-reinstall-" + UUID().uuidString)
        defer { try? files.removeItem(at: home); try? files.removeItem(at: install) }
        let id = "audit.reinstall", paths = ContainerPaths(home: home)
        _ = try fixture(home, id: id)
        let app = install.appendingPathComponent(id + ".app")
        try files.createDirectory(at: app, withIntermediateDirectories: true)
        let root = try GameDataStorage.createRoot(for: app, bundleIdentifier: id, paths: paths)
        let data = paths.gameContainer(for: id).appendingPathComponent("Data")
        let documents = root.appendingPathComponent("Data/Documents")
        try files.createSymbolicLink(at: data.appendingPathComponent("Documents"), withDestinationURL: documents)
        let library = root.appendingPathComponent("Data/Library")
        try files.createDirectory(at: library, withIntermediateDirectories: true)
        try Data("existing download".utf8).write(to: library.appendingPathComponent("asset"))
        try files.createSymbolicLink(at: data.appendingPathComponent("Library"), withDestinationURL: library)
        #expect(!files.fileExists(atPath: documents.path))
        try GameDataStorage.prepare(for: app, bundleIdentifier: id, paths: paths)
        for name in GameDataStorage.names {
            #expect(files.fileExists(atPath: root.appendingPathComponent("Data/" + name).path))
        }
        #expect(try String(contentsOf: library.appendingPathComponent("asset"), encoding: .utf8) == "existing download")
        #expect(try files.destinationOfSymbolicLink(atPath: data.appendingPathComponent("Documents").path) == documents.path)
        #expect(try GameDataStorage.prepare(for: app, bundleIdentifier: id, paths: paths) == root)
    }

    @Test func unrelatedDocumentsLinkIsNotRepairedOrOverwritten() throws {
        let home = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: home) }
        let id = "audit.unrelated", paths = ContainerPaths(home: home), app = try fixture(home, id: id)
        let unrelated = home.appendingPathComponent("PersonalDocuments")
        let link = paths.gameContainer(for: id).appendingPathComponent("Data/Documents")
        try files.createSymbolicLink(at: link, withDestinationURL: unrelated)
        #expect(throws: GameDataStorage.Failure.self) {
            try GameDataStorage.prepare(for: app, bundleIdentifier: id, paths: paths)
        }
        #expect(try files.destinationOfSymbolicLink(atPath: link.path) == unrelated.path)
        #expect(!files.fileExists(atPath: unrelated.path))
    }

    @Test(arguments: [false, true]) func missingOwnedDocumentsRestoresOnlyUnambiguousBackup(conflicting: Bool) throws {
        let home = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: home) }
        let id = "audit.restore", paths = ContainerPaths(home: home), app = try fixture(home, id: id)
        let container = paths.gameContainer(for: id)
        let root = try GameDataStorage.createRoot(for: app, bundleIdentifier: id, paths: paths)
        let target = root.appendingPathComponent("Data/Documents")
        try files.createSymbolicLink(at: container.appendingPathComponent("Data/Documents"), withDestinationURL: target)
        let original = container.appendingPathComponent("MulgDataBackup/" + UUID().uuidString + "/Documents")
        try files.createDirectory(at: original, withIntermediateDirectories: true)
        try Data("retained save".utf8).write(to: original.appendingPathComponent("save"))
        if conflicting {
            let other = container.appendingPathComponent("MulgDataBackup/" + UUID().uuidString + "/Documents")
            try files.createDirectory(at: other, withIntermediateDirectories: true)
            try Data("different save".utf8).write(to: other.appendingPathComponent("save"))
            #expect(throws: GameDataStorage.Failure.self) {
                try GameDataStorage.prepare(for: app, bundleIdentifier: id, paths: paths)
            }
            #expect(!files.fileExists(atPath: target.path))
            #expect(try String(contentsOf: other.appendingPathComponent("save"), encoding: .utf8) == "different save")
        } else {
            try GameDataStorage.prepare(for: app, bundleIdentifier: id, paths: paths)
            #expect(try String(contentsOf: target.appendingPathComponent("save"), encoding: .utf8) == "retained save")
        }
        #expect(try String(contentsOf: original.appendingPathComponent("save"), encoding: .utf8) == "retained save")
    }

    @Test func copyingInterruptionRetriesAndPublishingInterruptionFinishesWithoutLosingOriginal() throws {
        let home = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: home) }
        let id = "audit.interrupted", paths = ContainerPaths(home: home), app = try fixture(home, id: id)
        let root = try GameDataStorage.createRoot(for: app, bundleIdentifier: id, paths: paths)
        let container = paths.gameContainer(for: id), source = container.appendingPathComponent("Data/Library")
        try files.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: source.appendingPathComponent("asset"))
        let journal = paths.mulgStateDirectory.appendingPathComponent("DataMigrations/" + id + ".json")
        let stage = root.appendingPathComponent("Data/.mulg-copy-test")
        try files.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("incomplete".utf8).write(to: stage.appendingPathComponent("asset"))
        let migration = GameDataStorage.Migration(name: "Library", source: source, target: root.appendingPathComponent("Data/Library"), staged: stage,
            backup: container.appendingPathComponent("MulgDataBackup/test/Library"))
        try GameDataStorage.save(migration, journal: journal)
        try GameDataStorage.prepare(for: app, bundleIdentifier: id, paths: paths)
        #expect(try String(contentsOf: source.appendingPathComponent("asset"), encoding: .utf8) == "original")
        #expect(!files.fileExists(atPath: journal.path))
    }

    @Test func conflictingCopyAndUnavailableDriveLeaveOriginalDataIntact() throws {
        let home = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: home) }
        let id = "audit.conflict", paths = ContainerPaths(home: home), app = try fixture(home, id: id)
        let root = try GameDataStorage.createRoot(for: app, bundleIdentifier: id, paths: paths)
        let source = paths.gameContainer(for: id).appendingPathComponent("Data/Library")
        try files.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: source.appendingPathComponent("asset"))
        try files.createDirectory(at: root.appendingPathComponent("Data/Library"), withIntermediateDirectories: true)
        try Data("existing external download".utf8).write(to: root.appendingPathComponent("Data/Library/other-asset"))
        #expect(throws: (any Error).self) { try GameDataStorage.prepare(for: app, bundleIdentifier: id, paths: paths) }
        #expect(try String(contentsOf: source.appendingPathComponent("asset"), encoding: .utf8) == "original")
        #expect(throws: (any Error).self) {
            try GameDataStorage.prepare(for: home.appendingPathComponent("missing-drive/game.app"), bundleIdentifier: id, paths: paths)
        }
        #expect(!files.fileExists(atPath: home.appendingPathComponent("missing-drive").path))
    }

    @Test func completeRemovalErasesDownloadsAliasesAndSettingsAndPreservesOtherGameAndIPA() throws {
        let home = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: home) }
        let id = "audit.remove", paths = ContainerPaths(home: home), app = try fixture(home, id: id)
        let other = try fixture(home, id: id + "2")
        let root = try GameDataStorage.prepare(for: app, bundleIdentifier: id, paths: paths)
        let otherRoot = try GameDataStorage.prepare(for: other, bundleIdentifier: id + "2", paths: paths)
        let ipa = home.appendingPathComponent("source.ipa")
        try Data("source".utf8).write(to: ipa)
        try SettingsStore(paths: paths).save(GameSettings(bundleIdentifier: id))
        try files.createDirectory(at: paths.applicationsDirectory, withIntermediateDirectories: true)
        try files.createSymbolicLink(at: paths.applicationsDirectory.appendingPathComponent(id + ".app"), withDestinationURL: app)
        // Library items a native Mac app with the same bundle ID could share go to the Trash; here they are
        // only recorded (a test must not fill the real Trash), and Mulg's own items are removed.
        var trashed: [URL] = []
        try GameCleanup.removeCompletely(app: app, bundleIdentifier: id, paths: paths,
                                         trash: { trashed.append($0); try files.removeItem(at: $0) })
        #expect(trashed.map(\.path).contains(paths.gameContainer(for: id).path))
        #expect(Set(trashed.map(\.path)).isDisjoint(with: [app.path, root.path, paths.settingsFile(for: id).path]))
        #expect(!files.fileExists(atPath: app.path) && !files.fileExists(atPath: root.path))
        #expect(!files.fileExists(atPath: paths.gameContainer(for: id).path))
        #expect(!files.fileExists(atPath: paths.settingsFile(for: id).path))
        #expect(files.fileExists(atPath: other.path) && files.fileExists(atPath: otherRoot.path) && files.fileExists(atPath: ipa.path))
    }

    @Test func archiveContainsGameBytesAndRestoreWritesBackIntoSupportDirectory() throws {
        let home = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: home) }
        let id = "audit.backup", paths = ContainerPaths(home: home), app = try fixture(home, id: id)
        let root = try GameDataStorage.prepare(for: app, bundleIdentifier: id, paths: paths)
        let local = root.appendingPathComponent("Data/Library/save")
        try Data("saved".utf8).write(to: local)
        let backup = SaveBackup(folder: home.appendingPathComponent("Backups"), paths: paths)
        let version = try backup.backUp(id)
        try Data("changed".utf8).write(to: local)
        try backup.restore(version, bundleIdentifier: id)
        #expect(try String(contentsOf: local, encoding: .utf8) == "saved")
        #expect(try String(contentsOf: root.appendingPathComponent("Data/Library/save"), encoding: .utf8) == "saved")
        #expect(try GameDataStorage.prepare(for: app, bundleIdentifier: id, paths: paths) == root)
    }

    @Test(arguments: ["audit.downloads", "audit.anothergame"])
    func legacyLibraryLinkIsRepairedWithoutMovingDownloadsAndPreferencesPersist(id: String) throws {
        let home = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: home) }
        let paths = ContainerPaths(home: home), app = try fixture(home, id: id)
        let root = try GameDataStorage.createRoot(for: app, bundleIdentifier: id, paths: paths)
        let external = root.appendingPathComponent("Data/Library")
        try files.createDirectory(at: external.appendingPathComponent("Preferences"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["downloadCompleted": true], format: .binary, options: 0)
            .write(to: external.appendingPathComponent("Preferences/" + id + ".plist"))
        let download = external.appendingPathComponent("AnyGameAssets/resource")
        try files.createDirectory(at: download.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("verified game download".utf8).write(to: download)
        let originalIdentity = try download.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        let local = paths.gameContainer(for: id).appendingPathComponent("Data/Library")
        try files.createSymbolicLink(at: local, withDestinationURL: external)
        try JSONEncoder().encode(GameDataStorage.Owner(bundleIdentifier: id))
            .write(to: root.appendingPathComponent("MulgRuntimeDataReady.json"))
        try GameDataStorage.prepare(for: app, bundleIdentifier: id, paths: paths)
        #expect((try local.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == false)
        let preferences = local.appendingPathComponent("Preferences/" + id + ".plist")
        #expect((try preferences.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == false)
        #expect(try Data(contentsOf: preferences) == Data(contentsOf: external.appendingPathComponent("Preferences/" + id + ".plist")))
        try PropertyListSerialization.data(fromPropertyList: ["downloadCompleted": true, "nextSession": true], format: .binary, options: 0)
            .write(to: preferences, options: .atomic)
        let saved = try Data(contentsOf: preferences)
        try GameDataStorage.prepare(for: app, bundleIdentifier: id, paths: paths)
        #expect(try Data(contentsOf: preferences) == saved)
        #expect(try String(contentsOf: local.appendingPathComponent("AnyGameAssets/resource"), encoding: .utf8) == "verified game download")
        #expect(String(describing: try download.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier)
            == String(describing: originalIdentity), "the download was neither moved nor recopied")
    }

    @Test func initializedStorageRejectsUnrelatedLibraryLinks() throws {
        let home = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: home) }
        let id = "audit.foreign", paths = ContainerPaths(home: home), app = try fixture(home, id: id)
        let root = try GameDataStorage.createRoot(for: app, bundleIdentifier: id, paths: paths)
        let personal = home.appendingPathComponent("UnrelatedLibrary")
        try files.createDirectory(at: personal, withIntermediateDirectories: true)
        let local = paths.gameContainer(for: id).appendingPathComponent("Data/Library")
        try files.createSymbolicLink(at: local, withDestinationURL: personal)
        try JSONEncoder().encode(GameDataStorage.Owner(bundleIdentifier: id))
            .write(to: root.appendingPathComponent("MulgRuntimeDataReady.json"))
        #expect(throws: GameDataStorage.Failure.self) { try GameDataStorage.prepare(for: app, bundleIdentifier: id, paths: paths) }
        #expect(try files.destinationOfSymbolicLink(atPath: local.path) == personal.path)
    }

    @Test func initializedRuntimeKeepsMacOSLibraryAndBacksUpActualExternalDownloads() throws {
        let home = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: home) }
        let id = "audit.initialized", paths = ContainerPaths(home: home), app = try fixture(home, id: id)
        let root = try GameDataStorage.createRoot(for: app, bundleIdentifier: id, paths: paths)
        let external = root.appendingPathComponent("Data/Library/MihoyoDownload/Persistent/asset")
        try files.createDirectory(at: external.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("external game update".utf8).write(to: external)
        try JSONEncoder().encode(GameDataStorage.Owner(bundleIdentifier: id)).write(to: root.appendingPathComponent("MulgRuntimeDataReady.json"))
        let localLibrary = paths.gameContainer(for: id).appendingPathComponent("Data/Library")
        try files.createDirectory(at: localLibrary, withIntermediateDirectories: true)
        try GameDataStorage.prepare(for: app, bundleIdentifier: id, paths: paths)
        #expect((try localLibrary.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true)
        let backup = SaveBackup(folder: home.appendingPathComponent("Backups"), paths: paths)
        let version = try backup.backUp(id)
        try Data("changed".utf8).write(to: external)
        try backup.restore(version, bundleIdentifier: id)
        #expect(try String(contentsOf: external, encoding: .utf8) == "external game update")
        #expect((try localLibrary.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true)
    }
}
