import Foundation
import Testing
import MulgContracts
@testable import MulgLibrary

@Suite("Full removal of a game's installed files")
struct GameRemovalScanTests {
    let files = FileManager.default

    func makeApp(_ url: URL, id: String, converted: Bool, groups: [String] = []) throws {
        try files.createDirectory(at: url, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Info.plist"))
        if converted {
            try PropertyListSerialization.data(fromPropertyList: ["com.apple.security.application-groups": groups], format: .xml, options: 0)
                .write(to: url.appendingPathComponent("MulgOriginalEntitlements.plist"))
        }
    }

    @Test func removesVerifiedLocationsAndKeepsNameOnlyAndSharedData() throws {
        let home = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let drive = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: home); try? files.removeItem(at: drive) }
        let id = "audit.scan", paths = ContainerPaths(home: home)
        let app = drive.appendingPathComponent("Games/" + id + ".app")
        try makeApp(app, id: id, converted: true, groups: ["group.audit.own", "group.audit.shared"])
        let root = try GameDataStorage.createRoot(for: app, bundleIdentifier: id, paths: paths)
        // An older converted copy in the drive's Applications folder, with its own Support folder.
        let copy = drive.appendingPathComponent("Applications/Copy.app")
        try makeApp(copy, id: id, converted: true)
        let copyRoot = try GameDataStorage.createRoot(for: copy, bundleIdentifier: id, paths: paths)
        let native = drive.appendingPathComponent("Applications/Native.app")
        try makeApp(native, id: id, converted: false)
        // Deep inside an unrelated folder: not an install location, never looked at.
        let buried = drive.appendingPathComponent("Projects/old/stuff/Buried.app")
        try makeApp(buried, id: id, converted: true)
        // Another installed game shares one app group.
        let other = drive.appendingPathComponent("Games/other.app")
        try makeApp(other, id: "audit.other", converted: true, groups: ["group.audit.shared"])
        try files.createDirectory(at: paths.applicationsDirectory, withIntermediateDirectories: true)
        try files.createSymbolicLink(at: paths.applicationsDirectory.appendingPathComponent("audit.other.app"), withDestinationURL: other)
        let groupRoot = home.appendingPathComponent("Library/Group Containers")
        for group in ["group.audit.own", "group.audit.shared"] {
            try files.createDirectory(at: groupRoot.appendingPathComponent(group), withIntermediateDirectories: true)
        }
        let documents = home.appendingPathComponent("Documents")
        try files.createDirectory(at: documents, withIntermediateDirectories: true)
        let leftover = documents.appendingPathComponent(id + ".json"), unrelated = documents.appendingPathComponent(id + "er.json")
        try Data().write(to: leftover); try Data().write(to: unrelated)
        // A recorded location on a drive that is not connected.
        let missing = URL(fileURLWithPath: "/Volumes/MulgMissingDrive-\(UUID().uuidString)/Games/Support/" + id)
        var recorded = try JSONDecoder().decode([URL].self, from: Data(contentsOf: GameDataStorage.locationsFile(id, paths: paths)))
        recorded.append(missing)
        try JSONEncoder().encode(recorded).write(to: GameDataStorage.locationsFile(id, paths: paths))

        let inventory = try GameRemovalScan.discover(app: app, bundleIdentifier: id, paths: paths, volumes: [drive])
        func real(_ url: URL) -> String { url.resolvingSymlinksInPath().path }
        let found = Dictionary(uniqueKeysWithValues: inventory.items.map { (real($0.url), $0.kind) })
        #expect(found[real(app)] == .bundle && found[real(copy)] == .bundle)
        #expect(found[real(root)] == .support && found[real(copyRoot)] == .support)
        for kept in [native, buried, other, unrelated, leftover,
                     groupRoot.appendingPathComponent("group.audit.own"), groupRoot.appendingPathComponent("group.audit.shared")] {
            #expect(found[real(kept)] == nil)
        }
        #expect(inventory.nativeApps.map(real) == [real(native)])
        #expect(inventory.sharedGroups == ["group.audit.own", "group.audit.shared"])
        #expect(inventory.unavailableRoots == [missing])

        // A locked file (copied from another Mac) must not block the removal.
        let locked = root.appendingPathComponent("Data/locked")
        try Data("locked".utf8).write(to: locked)
        try files.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        var trashedLeftovers: [String] = []
        #expect {
            try GameCleanup.removeCompletely(app: app, bundleIdentifier: id, paths: paths, inventory: inventory,
                                             trash: { try files.removeItem(at: $0) },
                                             trashLeftover: { trashedLeftovers.append(real($0)); try files.removeItem(at: $0) })
        } throws: { ($0 as? GameCleanup.IncompleteRemoval)?.issues.contains { $0.contains(missing.path) } == true }
        #expect(trashedLeftovers.isEmpty)
        for gone in [app, root, copy, copyRoot] {
            #expect(!files.fileExists(atPath: gone.path))
        }
        for kept in [native, buried, other, unrelated, leftover,
                     groupRoot.appendingPathComponent("group.audit.own"), groupRoot.appendingPathComponent("group.audit.shared")] {
            #expect(files.fileExists(atPath: kept.path))
        }
        // Only the disconnected location waits for a retry; the location index is kept for it.
        let pending = try GameCleanup.pendingRemovals(paths: paths)
        #expect(pending.map(\.bundleIdentifier) == [id] && pending[0].remaining.map(\.url) == [missing])
        #expect(files.fileExists(atPath: GameDataStorage.locationsFile(id, paths: paths).path))
    }

    @Test func refusedDeletionIsRetriedAndThenCleared() throws {
        let home = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: home) }
        let id = "audit.retry", paths = ContainerPaths(home: home)
        let app = home.appendingPathComponent("External/" + id + ".app")
        try makeApp(app, id: id, converted: false)
        let root = try GameDataStorage.createRoot(for: app, bundleIdentifier: id, paths: paths)
        // A plain (no inventory) removal still handles every recorded folder and keeps going past a failure.
        #expect(throws: GameCleanup.IncompleteRemoval.self) {
            try GameCleanup.removeCompletely(app: app, bundleIdentifier: id, paths: paths,
                remove: { url in
                    if url.path == root.path { throw CocoaError(.fileWriteNoPermission) }
                    try files.removeItem(at: url)
                }, trash: { try files.removeItem(at: $0) })
        }
        #expect(files.fileExists(atPath: root.path) && !files.fileExists(atPath: app.path))
        #expect(try GameCleanup.pendingRemovals(paths: paths).first?.remaining.map(\.url.path) == [root.path])
        try GameCleanup.removeCompletely(app: app, bundleIdentifier: id, paths: paths, trash: { try files.removeItem(at: $0) })
        #expect(!files.fileExists(atPath: root.path))
        #expect(try GameCleanup.pendingRemovals(paths: paths).isEmpty)
        #expect(!files.fileExists(atPath: GameDataStorage.locationsFile(id, paths: paths).path))
    }

    @Test func permissionRefusalsNameTheExactItemsForTheHostToAskAbout() throws {
        let home = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: home) }
        let id = "audit.denied", paths = ContainerPaths(home: home)
        let app = home.appendingPathComponent("External/" + id + ".app")
        try makeApp(app, id: id, converted: false)
        let container = paths.gameContainer(for: id)
        try files.createDirectory(at: container, withIntermediateDirectories: true)
        // The protected container refuses; everything else is still removed.
        do {
            try GameCleanup.removeCompletely(app: app, bundleIdentifier: id, paths: paths, trash: { url in
                if url.path == container.path { throw CocoaError(.fileWriteNoPermission, userInfo: [NSURLErrorKey: url]) }
                try files.removeItem(at: url)
            })
            Issue.record("expected a refusal")
        } catch {
            #expect(GameCleanup.deniedItems(in: error).map(\.path) == [container.path])
        }
        #expect(!files.fileExists(atPath: app.path) && files.fileExists(atPath: container.path))
        let plain = CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: "/x/y"])
        #expect(GameCleanup.deniedItems(in: plain).map(\.path) == ["/x/y"])
        #expect(GameCleanup.deniedItems(in: CocoaError(.fileNoSuchFile)).isEmpty)
        #expect(throws: GameCleanup.AccessDenied.self) {
            try GameCleanup.guarded(container) { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)) }
        }
    }

    @Test func nameOnlyMatchesAreExactBundleIDs() {
        #expect(GameRemovalScan.leftoverName("com.game", id: "com.game"))
        #expect(GameRemovalScan.leftoverName("com.game.plist", id: "com.game"))
        #expect(!GameRemovalScan.leftoverName("com.gamer", id: "com.game"))
        #expect(!GameRemovalScan.leftoverName("com.game.other.plist", id: "com.game"))
    }
}
