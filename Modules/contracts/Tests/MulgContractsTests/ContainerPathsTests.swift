import Foundation
import Testing
@testable import MulgContracts

@Suite("ContainerPaths")
struct ContainerPathsTests {
    let paths = ContainerPaths(home: URL(fileURLWithPath: "/Volumes/Home/alex", isDirectory: true))

    @Test("Paths are built from the given home folder, not from /Users/<login name>")
    func usesGivenHome() {
        #expect(paths.mulgContainer.path
            == "/Volumes/Home/alex/Library/Containers/io.mulg.Mulg")
    }

    @Test("Folder names match upstream Mulg")
    func upstreamFolderNames() {
        #expect(paths.settingsFile(for: "com.miHoYo.GenshinImpact").path
            == "/Volumes/Home/alex/Library/Containers/io.mulg.Mulg/App Settings/com.miHoYo.GenshinImpact.plist")
        #expect(paths.keymapDirectory(for: "com.example").lastPathComponent == "com.example")
        #expect(paths.keymappingDirectory.lastPathComponent == "Keymapping")
        #expect(paths.mulgChainDatabase(for: "com.example").lastPathComponent == "com.example.db")
        #expect(paths.applicationsDirectory.lastPathComponent == "Applications")
    }

    @Test("The real home folder is an absolute path")
    func realHomeIsAbsolute() {
        #expect(ContainerPaths.realHomeDirectory().path.hasPrefix("/"))
    }
}

@Suite("SettingsStore")
struct SettingsStoreTests {
    private func temporaryStore() throws -> SettingsStore {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("mulg-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return SettingsStore(paths: ContainerPaths(home: home))
    }

    @Test("Concurrent edits to separate fields both survive")
    func concurrentMerge() async throws {
        let store = try temporaryStore()
        let base = GameSettings(bundleIdentifier: "com.example.concurrent")
        try store.save(base)
        var host = base
        host.iosDeviceModel = "iPad17,3"
        var runtime = base
        runtime.mulg.diagnostics.performanceOverlay = true
        let first = host, second = runtime
        async let hostSave = Task.detached { try store.save(first, basedOn: base) }.value
        async let runtimeSave = Task.detached { try store.save(second, basedOn: base) }.value
        _ = try await (hostSave, runtimeSave)
        let saved = store.load(bundleIdentifier: base.bundleIdentifier).settings
        #expect(saved.iosDeviceModel == first.iosDeviceModel)
        #expect(saved.mulg.diagnostics.performanceOverlay)
    }

    @Test("An unreadable newer file is never overwritten by a merged edit")
    func mergedEditPreservesCorruptFile() throws {
        let store = try temporaryStore()
        let base = GameSettings(bundleIdentifier: "com.example.corrupt")
        try store.save(base)
        let file = store.paths.settingsFile(for: base.bundleIdentifier)
        let corrupt = Data("preserve me".utf8)
        try corrupt.write(to: file)
        var edited = base
        edited.mulg.diagnostics.performanceOverlay = true
        #expect(throws: SettingsStoreError.self) { try store.save(edited, basedOn: base) }
        #expect(try Data(contentsOf: file) == corrupt)
    }

    @Test("A missing file gives defaults with no problem reported")
    func missingFile() throws {
        let result = try temporaryStore().load(bundleIdentifier: "com.example.new")
        #expect(result.problem == nil)
        #expect(result.settings.bundleIdentifier == "com.example.new")
    }

    @Test("A corrupt file gives defaults and reports why")
    func corruptFile() throws {
        let store = try temporaryStore()
        let file = store.paths.settingsFile(for: "com.example.broken")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a property list".utf8).write(to: file)

        let result = store.load(bundleIdentifier: "com.example.broken")
        #expect(result.settings == GameSettings(bundleIdentifier: "com.example.broken"))
        guard case .unreadable(let path, _) = result.problem else {
            Issue.record("expected an unreadable-file problem")
            return
        }
        #expect(path == file.path)
    }

    @Test("Saved settings load back unchanged")
    func saveThenLoad() throws {
        let store = try temporaryStore()
        var settings = GameSettings(bundleIdentifier: "com.miHoYo.GenshinImpact")
        settings.iosDeviceModel = "iPad17,3"
        settings.mulg.controls.cursorKeyBehaviour = .toggle
        try store.save(settings)

        let result = store.load(bundleIdentifier: "com.miHoYo.GenshinImpact")
        #expect(result.problem == nil)
        #expect(result.settings == settings)
    }

    @Test("A copied settings file cannot redirect saves to another game")
    func copiedFile() throws {
        let store = try temporaryStore()
        var copied = GameSettings(bundleIdentifier: "com.example.other")
        copied.iosDeviceModel = "iPad17,3"
        let target = store.paths.settingsFile(for: "com.example.game")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SettingsStore.encode(copied).write(to: target)

        let loaded = store.load(bundleIdentifier: "com.example.game")
        #expect(loaded.problem == nil)
        #expect(loaded.settings.bundleIdentifier == "com.example.game")
        #expect(loaded.settings.iosDeviceModel == copied.iosDeviceModel)
        try store.save(loaded.settings)
        #expect(!FileManager.default.fileExists(atPath: store.paths.settingsFile(for: "com.example.other").path))
    }
}
