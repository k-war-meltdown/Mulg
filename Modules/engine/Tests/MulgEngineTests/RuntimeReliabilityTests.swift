import Foundation
import ObjectiveC
import Testing
import MulgContracts
import MulgEngineHooks
@testable import MulgEngine

private final class HookFixture: NSObject {
    @objc dynamic func answer() -> Int { 7 }
}

private final class ABIFixture: NSObject { @objc dynamic func answer() -> Int { 7 } }
private class FirstDriver: NSObject { @objc dynamic func driverAnswer() -> Int { 21 } }
private final class SecondDriver: NSObject { @objc dynamic func driverAnswer() -> Int { 42 } }
private final class InheritedDriver: FirstDriver {}
private let driverHook: @convention(c) (AnyObject, Selector) -> Int = { object, selector in
    let replacement = unsafeBitCast(driverHook, to: IMP.self)
    guard let cls = object_getClass(object), let original = mulg_swizzle_original(cls, selector, replacement) else { return -1 }
    return unsafeBitCast(original, to: (@convention(c) (AnyObject, Selector) -> Int).self)(object, selector) + 1
}

@Suite("Hook installation") @MainActor
struct HookInstallationTests {
    @Test func rejectsChangedABIWithoutReplacingTheMethod() {
        let callback: @convention(c) (AnyObject, Selector) -> Int = { _, _ in 13 }
        let replacement = unsafeBitCast(callback, to: IMP.self)
        let selector = NSSelectorFromString("answer")
        var previous: IMP?
        #expect(mulg_swizzle_checked_owned("test:abi", ABIFixture.self, selector, replacement, &previous, "@", []) == .signatureMismatch)
        #expect(previous == nil)
        #expect(ABIFixture().answer() == 7)
        #expect(mulg_swizzle_checked_owned("test:abi", ABIFixture.self, selector, replacement, &previous, "q", []) == .replaced)
        #expect(ABIFixture().answer() == 13)
    }

    @Test("A hook by name on a class this game lacks does not apply; a missing method still counts")
    func absentEngineClassIsNotApplicable() {
        let callback: @convention(c) (AnyObject, Selector) -> Int = { _, _ in 1 }
        let replacement = unsafeBitCast(callback, to: IMP.self)
        #expect(mulg_swizzle_instance_named_owned("controls", "MulgNoSuchEngineViewController",
                                                  NSSelectorFromString("prefersPointerLocked"), replacement, nil) == .classMissing)
        #expect(mulg_swizzle_instance_named_owned("controls", NSStringFromClass(HookFixture.self),
                                                  NSSelectorFromString("noSuchSelector"), replacement, nil) == .methodMissing)
        let registry = HookRegistry()
        registry.refreshInstallationReports()
        #expect(registry.notApplicable.contains { $0.target == "-MulgNoSuchEngineViewController.prefersPointerLocked" })
        #expect(!registry.missing.contains { $0.target == "-MulgNoSuchEngineViewController.prefersPointerLocked" })
        #expect(registry.missing.contains { $0.target.hasSuffix(".noSuchSelector") })
    }

    @Test("Reports are read again only after they change; claims find targets with or without -/+")
    func claimsReadChangedReportsOnly() throws {
        final class ClaimFixture: NSObject { @objc dynamic func value() -> Int { 1 } }
        let callback: @convention(c) (AnyObject, Selector) -> Int = { _, _ in 2 }
        let before = mulg_hook_installation_generation()
        #expect(mulg_swizzle_instance_owned("display", ClaimFixture.self, NSSelectorFromString("value"),
                                            unsafeBitCast(callback, to: IMP.self), nil) == .replaced)
        #expect(mulg_hook_installation_generation() != before)
        let registry = HookRegistry()
        let name = NSStringFromClass(ClaimFixture.self)
        try registry.claim("\(name).value", owner: .display, kind: .swizzle)
        try registry.claim("-\(name).value", owner: .display, kind: .swizzle, privateAPI: true)
        #expect(registry.entries["-\(name).value"]?.isPrivateAPI == true)
        #expect(throws: HookRegistry.ClaimError.self) { try registry.claim("\(name).value", owner: .controls, kind: .swizzle) }
        let unchanged = mulg_hook_installation_generation()
        registry.refreshInstallationReports()
        #expect(mulg_hook_installation_generation() == unchanged)
    }

    @Test func routesOriginalsByConcreteAndInheritedClass() {
        let replacement = unsafeBitCast(driverHook, to: IMP.self)
        let selector = NSSelectorFromString("driverAnswer")
        for cls in [FirstDriver.self, SecondDriver.self, InheritedDriver.self] {
            #expect(mulg_swizzle_instance_owned("test:drivers", cls, selector, replacement, nil) == .replaced)
        }
        #expect(FirstDriver().driverAnswer() == 22)
        #expect(SecondDriver().driverAnswer() == 43)
        #expect(InheritedDriver().driverAnswer() == 22)
    }
    @Test func platformAnswersAreRestrictedToGameOwnedImages() {
        #expect(mulg_engine_is_game_image("/Games/Game.app/Game", "/Games/Game.app"))
        #expect(mulg_engine_is_game_image("/Games/Game.app/Frameworks/Unity.framework/Unity", "/Games/Game.app"))
        #expect(!mulg_engine_is_game_image("/Games/Game.app.backup/Game", "/Games/Game.app"))
        #expect(!mulg_engine_is_game_image("/System/Library/UIKit", "/Games/Game.app"))
        #expect(!mulg_engine_is_game_image("/Games/Game.app/PlugIns/MulgBridge.bundle/Contents/MacOS/MulgBridge", "/Games/Game.app"))
        #expect(!mulg_engine_is_game_image("/Games/Game.app/Frameworks/MulgRuntime.framework/MulgRuntime", "/Games/Game.app"))
    }

    @Test func nativeHelperPlatformIsPreservedAndMalformedMetadataFailsClosed() {
        struct Image { var header: mach_header_64; var build: build_version_command }
        for platform in [UInt32(PLATFORM_MACOS), UInt32(PLATFORM_IOS), UInt32(PLATFORM_MACCATALYST)] {
            var image = Image(header: mach_header_64(), build: build_version_command())
            image.header.magic = UInt32(MH_MAGIC_64)
            image.header.ncmds = 1
            image.header.sizeofcmds = UInt32(MemoryLayout<build_version_command>.size)
            image.build.cmd = UInt32(LC_BUILD_VERSION)
            image.build.cmdsize = image.header.sizeofcmds
            image.build.platform = platform
            withUnsafePointer(to: &image) {
                #expect(mulg_engine_image_uses_ios_platform(UnsafeRawPointer($0).assumingMemoryBound(to: mach_header.self)) == (platform != PLATFORM_MACOS))
            }
            image.build.cmdsize += 1
            withUnsafePointer(to: &image) {
                #expect(!mulg_engine_image_uses_ios_platform(UnsafeRawPointer($0).assumingMemoryBound(to: mach_header.self)))
            }
        }
        #expect(!mulg_engine_image_uses_ios_platform(nil))
    }
    @Test func ownershipBeforeReplacementAndRepeatedInstall() {
        let first: @convention(c) (AnyObject, Selector) -> Int = { _, _ in 11 }
        let second: @convention(c) (AnyObject, Selector) -> Int = { _, _ in 99 }
        let replacement = unsafeBitCast(first, to: IMP.self)
        var previous: IMP?
        let selector = NSSelectorFromString("answer")
        #expect(mulg_swizzle_instance_owned("test:first", HookFixture.self, selector, replacement, &previous) == .replaced)
        let original = previous
        #expect(HookFixture().answer() == 11)
        #expect(mulg_swizzle_instance_owned("test:second", HookFixture.self, selector,
                                           unsafeBitCast(second, to: IMP.self), nil) == .conflict)
        #expect(HookFixture().answer() == 11)
        #expect(mulg_swizzle_instance_owned("test:first", HookFixture.self, selector, replacement, &previous) == .replaced)
        #expect(previous.map { unsafeBitCast($0, to: UInt.self) } == original.map { unsafeBitCast($0, to: UInt.self) })
    }
}

@Suite("Unreal path boundaries", .serialized)
struct UnrealPathBoundaryTests {
    @Test func singleSlashJoinsUseConfiguredRootsForAnyNewInstallation() {
        for volume in ["Games", "Fresh Install Drive"] {
            let root = "/Volumes/\(volume)/Support/example.newgame/Data"
            let bundle = "/Volumes/\(volume)/example.newgame.app"
            mulg_engine_configure_game_path_roots(["/Users/player", root, bundle], false)
            func repaired(_ path: String) -> String {
                path.withCString { String(cString: mulg_engine_fix_path($0)) }
            }
            let nested = root + "/Documents" + root + "/Documents/Cache"
            #expect(repaired(nested) == root + "/Documents/Cache")
            #expect(repaired(root + "/Documents/" + root + "/Documents/Cache") == root + "/Documents/Cache")
            #expect(repaired("/engine//Users/player/file") == "/engine//Users/player/file")
            #expect(repaired(root + "/Library/Caches" + root + "/Documents/Cache") == root + "/Documents/Cache")
            #expect(repaired(root + "/Documents" + root + "/Documents" + root + "/Documents/file") == root + "/Documents/file")
            #expect(repaired(root + "/Documents" + bundle + "/cookeddata/file") == bundle + "/cookeddata/file")
            for prefix in ["/Archive", "/Documents/Archive", "/Documents-old"] {
                let literal = root + prefix + root + "/Documents/Cache"
                #expect(repaired(literal) == literal)
            }
            let sibling = root + "/Documents" + root + ".other/Documents/file"
            #expect(repaired(sibling) == sibling)
            #expect(repaired(root + "/Documents/Cache") == root + "/Documents/Cache")
        }
        mulg_engine_configure_unreal_paths(nil)
    }

    @Test func relocatedDataAndBundlePathsRespectBoundariesAndLatestSuffix() {
        let data = "/Volumes/Games/Support/example.game/Data"
        let bundle = "/Volumes/Games/example.game.app"
        mulg_engine_configure_unreal_paths(["/Users/alex/", "/Users/alex", data + "/", bundle])
        defer { mulg_engine_configure_unreal_paths(nil) }
        func repaired(_ path: String) -> String {
            path.withCString { String(cString: mulg_engine_fix_path($0)) }
        }
        #expect(repaired("/engine/Content/" + data + "/Library/shaders") == data + "/Library/shaders")
        #expect(repaired("/engine/Content/" + bundle + "/cookeddata/global.mbin") == bundle + "/cookeddata/global.mbin")
        #expect(repaired("/engine/" + data + "Elsewhere/shaders") == "/engine/" + data + "Elsewhere/shaders")
        #expect(repaired("/engine/" + bundle + ".backup/cookeddata") == "/engine/" + bundle + ".backup/cookeddata")
        // Root order cannot undo a later, more deeply joined absolute path.
        #expect(repaired("/engine/" + data + "//Users/alex/Documents") == "/Users/alex/Documents")
        #expect(repaired("/engine//Users/alex/" + data + "/Library") == data + "/Library")
        #expect(repaired(data + "/Library") == data + "/Library")
        mulg_engine_configure_unreal_paths(["/", "relative", ""])
        #expect(repaired("/engine//unrelated/file") == "/engine//unrelated/file")
        mulg_engine_configure_unreal_paths([data])
        mulg_engine_configure_unreal_paths(nil)
        #expect(repaired("/engine/" + data + "/Library") == "/engine/" + data + "/Library")
    }

    @Test func onlyRepairsTheExactHomeDirectory() {
        "/Users/alex".withCString { mulg_engine_configure_unreal_path_fix($0) }
        defer { mulg_engine_configure_unreal_path_fix(nil) }
        func repaired(_ path: String) -> String {
            path.withCString { String(cString: mulg_engine_fix_path($0)) }
        }
        #expect(repaired("/container//Users/alex/Documents/save") == "/Users/alex/Documents/save")
        #expect(repaired("/container//Users/alex") == "/Users/alex")
        #expect(repaired("/container//Users/alexander/save") == "/container//Users/alexander/save")
        #expect(repaired("/Users/alex/Documents/save") == "/Users/alex/Documents/save")
    }
}

@Suite("Sleep detection")
struct SleepDetectionTests {
    @Test func ordinaryPollingNeverQualifies() {
        var streak: UInt32 = 0
        for _ in 0..<1_000 { streak = mulg_engine_sleep_streak(streak, 100_000, 100_000_000, 0) }
        #expect(streak == 0)
        for _ in 0..<101 { streak = mulg_engine_sleep_streak(streak, 100_000, 100_000, 0) }
        #expect(streak == 101)
        #expect(mulg_engine_sleep_streak(streak, 100_000, 100_000, -1) == 0)
        #expect(mulg_engine_sleep_streak(streak, 1_000, 100_000, 0) == 0)
        #expect(mulg_engine_sleep_streak(streak, 100_000, 100_000_000, 0) == 0)
    }
}

@Suite("Cloud-aware shutdown")
struct ShutdownPolicyTests {
    @Test func waitsForAcknowledgementWorkButHasAHardDeadline() {
        var settings = EngineSettings()
        settings.shutdownGraceSeconds = 3
        settings.shutdownDeadlineSeconds = 15
        #expect(!ShutdownPolicy.shouldTerminate(elapsed: 2, backgroundTasks: 0, settings: settings))
        #expect(!ShutdownPolicy.shouldTerminate(elapsed: 4, backgroundTasks: 1, settings: settings))
        #expect(ShutdownPolicy.shouldTerminate(elapsed: 4, backgroundTasks: 0, settings: settings))
        #expect(ShutdownPolicy.shouldTerminate(elapsed: 15, backgroundTasks: 1, settings: settings))
        #expect(!ShutdownPolicy.shouldTerminate(elapsed: 4, backgroundTasks: 0, settings: settings, trackingAvailable: false))
        #expect(ShutdownPolicy.shouldTerminate(elapsed: 15, backgroundTasks: 0, settings: settings, trackingAvailable: false))
        settings.shutdownGraceSeconds = .nan
        settings.shutdownDeadlineSeconds = -.infinity
        #expect(settings.shutdownGrace == 3)
        #expect(settings.shutdownDeadline == 15)
        settings.shutdownGraceSeconds = 30
        settings.shutdownDeadlineSeconds = 1
        #expect(settings.shutdownDeadline == 30)
    }
}

@Suite("Runtime settings failures") @MainActor
struct RuntimeSettingsFailureTests {
    @Test func aFailedWriteDoesNotPublishOrChangeTheLiveSettingsAndCanBeRetried() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ContainerPaths(home: root), store = SettingsStore(paths: paths), id = "test.settings.failure"
        try FileManager.default.createDirectory(at: paths.appSettingsDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("blocks directory".utf8).write(to: paths.appSettingsDirectory)
        let context = ModuleContext(bundleIdentifier: id, paths: paths, settingsStore: store,
                                    settings: GameSettings(bundleIdentifier: id), launch: .normal, bridge: nil)
        var changes = 0
        context.events.subscribe(SettingsChanged.self) { _ in changes += 1 }
        #expect(!context.updateSettings { $0.mulg.graphics.metalFX.enabled = true })
        #expect(!context.settings.mulg.graphics.metalFX.enabled && changes == 0)
        try FileManager.default.removeItem(at: paths.appSettingsDirectory)
        #expect(context.updateSettings { $0.mulg.graphics.metalFX.enabled = true })
        #expect(context.settings.mulg.graphics.metalFX.enabled && changes == 1)
        #expect(store.load(bundleIdentifier: id).settings.mulg.graphics.metalFX.enabled)
    }
}

@Suite("Recovery journal")
struct RecoveryJournalTests {
    @Test func successfulStartupBreaksConsecutiveFailureStreak() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appendingPathComponent("launch")
        for _ in 0..<4 {
            let safe = SafeMode(marker: marker)
            _ = safe.beginLaunch(settings: GameSettings())
            safe.stage(.preparing, module: .controls)
            #expect(safe.record()?.module == .controls)
            safe.stage(.healthy)
            #expect(safe.unfinishedLaunches() == 0)
            #expect(safe.record()?.unfinishedLaunches == 0)
        }
        let recovered = SafeMode(marker: marker)
        #expect(recovered.beginLaunch() == .normal)
        #expect(recovered.record()?.runtimeProtocol == MulgVersion.runtimeProtocol)
        #expect(FileManager.default.fileExists(atPath: recovered.previousRecord.path))
        recovered.launchSucceeded()
        #expect(recovered.beginLaunch() == .normal)
    }
}

@MainActor private final class PrerequisiteFixture: GameModule {
    let id: ModuleID
    var fails = false
    var suppliesCore = false
    var didPrepare = false
    var didActivate = false
    var imageRetries = 0
    var isExperimental: Bool { id == .graphics }
    init(_ id: ModuleID) { self.id = id }
    func prepare(_ context: ModuleContext) throws {
        didPrepare = true
        if fails { throw CocoaError(.featureUnsupported) }
    }
    func prepareCore(_ context: ModuleContext) throws -> Bool { didPrepare = suppliesCore; return suppliesCore }
    func activate(_ context: ModuleContext) { didActivate = true }
    func imagesChanged(_ context: ModuleContext) { imageRetries += 1 }
}

@Suite("Module prerequisites and stable presentation") @MainActor
struct ModulePrerequisiteTests {
    private func context(launch: SafeMode.Launch = .normal) -> ModuleContext {
        let paths = ContainerPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        return ModuleContext(bundleIdentifier: "probe", paths: paths, settingsStore: SettingsStore(paths: paths),
                             settings: GameSettings(), launch: launch, bridge: nil)
    }
    @Test func failedEngineDoesNotStartDependents() {
        let engine = PrerequisiteFixture(.engine)
        engine.fails = true
        let controls = PrerequisiteFixture(.controls)
        let host = ModuleHost(context: context(), modules: [controls, engine])
        host.prepareAll(); host.activateAll()
        #expect(!controls.didPrepare && !controls.didActivate)
        #expect(host.reports[.controls]?.state == .unavailable("engine did not prepare"))
    }
    @Test func safeModeKeepsCoreServicesAndPreparesOnlyOnce() {
        let engine = PrerequisiteFixture(.engine)
        let graphics = PrerequisiteFixture(.graphics)
        graphics.suppliesCore = true
        let host = ModuleHost(context: context(launch: .safe(unfinishedLaunches: 2)), modules: [graphics, engine])
        host.prepareAll(); host.prepareAll(); host.activateAll()
        #expect(graphics.didPrepare && graphics.didActivate)
        #expect(host.reports[.graphics]?.state == .coreOnly(String(describing: ModuleState.offInSafeMode)))
        #expect(host.modulesOffInSafeMode == [.graphics])
    }
    @Test func lateImagesOnlyRetryRunningModulesWithoutRepeatingStartup() {
        let engine = PrerequisiteFixture(.engine)
        let graphics = PrerequisiteFixture(.graphics)
        let host = ModuleHost(context: context(launch: .safe(unfinishedLaunches: 2)), modules: [graphics, engine])
        host.prepareAll(); host.activateAll()
        host.retryUnresolvedHooks(); host.retryUnresolvedHooks()
        #expect(engine.imageRetries == 2)
        #expect(graphics.imageRetries == 0)
        #expect(host.reports[.engine]?.state == .active)
        #expect(!graphics.didPrepare && !graphics.didActivate)
    }
}
