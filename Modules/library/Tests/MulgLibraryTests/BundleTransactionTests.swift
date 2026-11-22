#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import MulgContracts
@testable import MulgLibrary
import Testing

@Suite("Interrupted bundle replacement")
struct BundleTransactionTests {
    @Test func committedCleanupFailureKeepsWorkingGameAndRetriesWithoutBlockingLaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = FileManager.default, id = "audit.cleanup", paths = ContainerPaths(home: root)
        defer { try? files.removeItem(at: root) }
        let app = root.appendingPathComponent(id + ".app"), backup = root.appendingPathComponent(".mulg-backup-test.app")
        for (directory, value) in [(app, "verified new"), (backup, "old icon")] {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(value.utf8).write(to: directory.appendingPathComponent("asset"))
        }
        let record = BundleTransaction.Record(bundleIdentifier: id, target: app,
            staged: root.appendingPathComponent(".mulg-stage-test.app"), backup: backup,
            link: nil, linkBackup: nil, hadTarget: true, hadLink: false, committed: true)
        try BundleTransaction.save(record, paths: paths)
        let denied: (URL) throws -> Void = { _ in throw CocoaError(.fileWriteNoPermission) }
        try BundleTransaction.recover(id, paths: paths, remove: denied, verify: { target in
            let value = try String(contentsOf: target.appendingPathComponent("asset"), encoding: .utf8)
            #expect(value == "verified new")
        })
        #expect(!BundleTransaction.hasPendingRecovery(id, paths: paths))
        #expect(BundleTransaction.exists(backup))
        #expect(try files.contentsOfDirectory(atPath: BundleTransaction.cleanupFolder(paths).path).count == 1)
        try BundleTransaction.recover(id, paths: paths, remove: denied, verify: { _ in })
        #expect(throws: CocoaError.self) { try BundleTransaction.retryCleanup(id, paths: paths, strict: true, remove: denied) }
        try BundleTransaction.recover(id, paths: paths, verify: { _ in })
        #expect(!BundleTransaction.exists(backup))
        #expect(try files.contentsOfDirectory(atPath: BundleTransaction.cleanupFolder(paths).path).isEmpty)
        #expect(try String(contentsOf: app.appendingPathComponent("asset"), encoding: .utf8) == "verified new")
    }

    @Test func malformedCleanupRecordCannotRemoveAnUnrelatedBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileManager.default, id = "audit.cleanup", paths = ContainerPaths(home: root)
        let unrelated = root.appendingPathComponent("Keep.app")
        try files.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let record = BundleTransaction.Record(bundleIdentifier: id, target: root.appendingPathComponent(id + ".app"),
            staged: root.appendingPathComponent(".mulg-stage-test.app"), backup: unrelated,
            link: nil, linkBackup: nil, hadTarget: true, hadLink: false, committed: true)
        let queue = BundleTransaction.cleanupFolder(paths)
        try files.createDirectory(at: queue, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: queue.appendingPathComponent(id + ".cleanup-test.json"))
        #expect(throws: CocoaError.self) { try BundleTransaction.retryCleanup(id, paths: paths) }
        #expect(BundleTransaction.exists(unrelated))
    }

    @Test func failedCopyDoesNotLeaveStagingBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("games/audit.copy.app")
        #expect(throws: (any Error).self) {
            try BundleTransaction.replace(root.appendingPathComponent("missing.app"), at: destination,
                bundleIdentifier: "audit.copy", paths: ContainerPaths(home: root), verify: { _ in })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path).isEmpty)
    }
    @Test func metadataFailureKeepsLiveInfoAndSuccessfulEditPreservesOtherEnvironmentKeys() throws {
        enum Failure: Error { case sign }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "audit.metadata", paths = ContainerPaths(home: root)
        let app = root.appendingPathComponent(id + ".app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let file = app.appendingPathComponent("Info.plist")
        let original = try PropertyListSerialization.data(fromPropertyList: ["LSEnvironment": ["OTHER": "kept"]], format: .xml, options: 0)
        try original.write(to: file)
        #expect(throws: Failure.self) {
            try GameInstaller.editMetadata(app: app, bundleIdentifier: id, paths: paths,
                update: { $0["LSApplicationCategoryType"] = "games" }, sign: { _ in throw Failure.sign }, verify: { _ in })
        }
        #expect(try Data(contentsOf: file) == original)
        try GameInstaller.editMetadata(app: app, bundleIdentifier: id, paths: paths, update: { tree in
            var environment = tree["LSEnvironment"] as? [String: String] ?? [:]
            environment["DYLD_LIBRARY_PATH"] = "/engine:"
            tree["LSEnvironment"] = environment
        }, sign: { _ in }, verify: { _ in })
        let saved = try #require(GameInstaller.infoPlist(app)?["LSEnvironment"] as? [String: String])
        #expect(saved == ["OTHER": "kept", "DYLD_LIBRARY_PATH": "/engine:"])
    }
    @Test func stagedEditPublishesBundleAndPluginCardsTogether() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "audit.publish", files = FileManager.default, paths = ContainerPaths(home: root)
        let app = root.appendingPathComponent(id + ".app"), store = root.appendingPathComponent("Plugins/" + id)
        let source = root.appendingPathComponent("candidate")
        for folder in [app, store, source] { try files.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("old".utf8).write(to: app.appendingPathComponent("version"))
        try Data("old".utf8).write(to: store.appendingPathComponent("old.dylib"))
        for name in ["new.dylib", "new.module.json"] { try Data(name.utf8).write(to: source.appendingPathComponent(name)) }
        try GameInstaller.editInstalled(app: app, bundleIdentifier: id, paths: paths, companions: [store: source],
            prepare: { working in
                try Data("new".utf8).write(to: working.appendingPathComponent("version"))
                try GameInstaller.installPlugins([source.appendingPathComponent("new.dylib")], into: working)
            }, sign: { _ in }, verify: { _ in })
        #expect(try String(contentsOf: app.appendingPathComponent("version"), encoding: .utf8) == "new")
        for name in ["new.dylib", "new.module.json"] {
            #expect(try Data(contentsOf: store.appendingPathComponent(name)) == Data(contentsOf: app.appendingPathComponent("Frameworks/UserPlugins/" + name)))
        }
        #expect(!BundleTransaction.exists(store.appendingPathComponent("old.dylib")))
        #expect(!BundleTransaction.hasPendingRecovery(id, paths: paths))
    }
    @Test(arguments: [false, true]) func pluginStoreAndBundleRecoverTogether(_ committed: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "audit.plugins", paths = ContainerPaths(home: root), files = FileManager.default
        let app = root.appendingPathComponent(id + ".app")
        let store = root.appendingPathComponent("Plugins/" + id)
        let stage = store.deletingLastPathComponent().appendingPathComponent(".mulg-companion-stage-test")
        let backup = store.deletingLastPathComponent().appendingPathComponent(".mulg-companion-backup-test")
        for (folder, value) in [(app, "new"), (store, "new"), (backup, "old")] {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(value.utf8).write(to: folder.appendingPathComponent("version"))
        }
        let appBackup = root.appendingPathComponent(".mulg-backup-test.app")
        try files.createDirectory(at: appBackup, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: appBackup.appendingPathComponent("version"))
        var record = BundleTransaction.Record(bundleIdentifier: id, target: app, staged: root.appendingPathComponent(".mulg-stage-test.app"),
            backup: appBackup, link: nil, linkBackup: nil, hadTarget: true, hadLink: false, committed: committed)
        record.companions = [.init(target: store, staged: stage, backup: backup, hadTarget: true)]
        try BundleTransaction.save(record, paths: paths)
        try BundleTransaction.recover(id, paths: paths, verify: { _ in })
        for folder in [app, store] {
            #expect(try String(contentsOf: folder.appendingPathComponent("version"), encoding: .utf8) == (committed ? "new" : "old"))
        }
        #expect(!BundleTransaction.hasPendingRecovery(id, paths: paths))
    }

    @Test func failedStagedEditPreservesInstalledBundleAndPluginStore() throws {
        enum Failure: Error { case signing }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("audit.edit.app"), store = root.appendingPathComponent("audit.edit")
        for folder in [app, store] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: folder.appendingPathComponent("version"))
        }
        #expect(throws: Failure.self) {
            try GameInstaller.editInstalled(app: app, bundleIdentifier: "audit.edit", paths: ContainerPaths(home: root),
                companions: [store: store], prepare: { working in
                    try Data("new".utf8).write(to: working.appendingPathComponent("version"))
                }, sign: { _ in throw Failure.signing }, verify: { _ in })
        }
        for folder in [app, store] { #expect(try String(contentsOf: folder.appendingPathComponent("version"), encoding: .utf8) == "old") }
    }
    @Test(arguments: [0, 1, 2, 3])
    func recoversEveryPersistedBoundary(_ boundary: Int) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ContainerPaths(home: root)
        let id = "com.example.recovery"
        let files = FileManager.default
        let target = root.appendingPathComponent(id + ".app")
        let staged = root.appendingPathComponent(".mulg-stage-test.app")
        let backup = root.appendingPathComponent(".mulg-backup-test.app")
        let link = paths.applicationsDirectory.appendingPathComponent(id + ".app")
        let linkBackup = paths.applicationsDirectory.appendingPathComponent(".mulg-link-test.app")
        for (bundle, value) in [(target, "old"), (staged, "new")] {
            try files.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data(value.utf8).write(to: bundle.appendingPathComponent("version"))
            try Data(value.utf8).write(to: bundle.appendingPathComponent("MulgOriginalEntitlements.plist"))
        }
        try files.createDirectory(at: paths.applicationsDirectory, withIntermediateDirectories: true)
        try files.createSymbolicLink(at: link, withDestinationURL: target)
        var record = BundleTransaction.Record(bundleIdentifier: id, target: target, staged: staged, backup: backup,
                                              link: link, linkBackup: linkBackup, hadTarget: true, hadLink: true)
        try BundleTransaction.save(record, paths: paths)
        try files.moveItem(at: target, to: backup)
        if boundary >= 1 { try files.moveItem(at: staged, to: target) }
        if boundary >= 2 {
            try files.moveItem(at: link, to: linkBackup)
            try files.createSymbolicLink(at: link, withDestinationURL: target)
        }
        if boundary == 3 { record.committed = true; try BundleTransaction.save(record, paths: paths) }
        // Reconstruct solely from disk, as a new host process would after a forced termination.
        try BundleTransaction.recover(id, paths: paths, verify: { bundle in
            _ = try String(contentsOf: bundle.appendingPathComponent("version"), encoding: .utf8)
        })
        #expect(try String(contentsOf: target.appendingPathComponent("version"), encoding: .utf8) == (boundary == 3 ? "new" : "old"))
        #expect(try String(contentsOf: target.appendingPathComponent("MulgOriginalEntitlements.plist"), encoding: .utf8) == (boundary == 3 ? "new" : "old"))
        #expect(try files.destinationOfSymbolicLink(atPath: link.path) == target.path)
        #expect(!BundleTransaction.exists(backup))
        #expect(!BundleTransaction.exists(BundleTransaction.journal(id, paths)))
        try BundleTransaction.recover(id, paths: paths, verify: { _ in }) // Recovery is idempotent.
    }

    @Test func failedPostPlacementVerificationRestoresThePreviousApp() throws {
        enum Rejected: Error { case signature }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "com.example.rejected"
        let target = root.appendingPathComponent(id + ".app")
        let source = root.appendingPathComponent("candidate.app")
        for (bundle, value) in [(target, "old"), (source, "new")] {
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data(value.utf8).write(to: bundle.appendingPathComponent("version"))
        }
        #expect(throws: Rejected.self) {
            try BundleTransaction.replace(source, at: target, bundleIdentifier: id, paths: ContainerPaths(home: root)) { bundle in
                if bundle == target, try String(contentsOf: bundle.appendingPathComponent("version"), encoding: .utf8) == "new" {
                    throw Rejected.signature
                }
            }
        }
        #expect(try String(contentsOf: target.appendingPathComponent("version"), encoding: .utf8) == "old")
    }

    @Test func malformedJournalCannotRemoveAnUnrelatedBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ContainerPaths(home: root)
        let id = "com.example.corrupt"
        let unrelated = root.appendingPathComponent("Keep.app")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let record = BundleTransaction.Record(bundleIdentifier: id, target: unrelated,
            staged: root.appendingPathComponent(".mulg-stage-test.app"), backup: root.appendingPathComponent(".mulg-backup-test.app"),
            link: nil, linkBackup: nil, hadTarget: false, hadLink: false)
        try BundleTransaction.save(record, paths: paths)
        #expect(throws: CocoaError.self) { try BundleTransaction.recover(id, paths: paths, verify: { _ in }) }
        #expect(BundleTransaction.exists(unrelated))
        #expect(BundleTransaction.exists(BundleTransaction.journal(id, paths)))
    }
}
#endif

@Suite("Code-only signature check")
struct CodeVerificationTests {
    @Test("Signed code passes, changed resources are not re-hashed, changed code fails")
    func checksCodeNotResources() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appendingPathComponent("Probe.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleExecutable": "Probe", "CFBundleIdentifier": "io.mulg.tests.probe",
                                   "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        let executable = app.appendingPathComponent("Probe")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        let resource = app.appendingPathComponent("asset.dat")
        try Data(repeating: 1, count: 4096).write(to: resource)
        try Command.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        try BundleTransaction.verifyCode(app)

        try Data(repeating: 2, count: 4096).write(to: resource)
        try BundleTransaction.verifyCode(app)

        let handle = try FileHandle(forWritingTo: executable)
        try handle.seek(toOffset: 0x4000)
        try handle.write(contentsOf: Data(repeating: 0xFF, count: 64))
        try handle.close()
        #expect(throws: BundleTransaction.CodeSignatureFailure.self) { try BundleTransaction.verifyCode(app) }
    }
}

