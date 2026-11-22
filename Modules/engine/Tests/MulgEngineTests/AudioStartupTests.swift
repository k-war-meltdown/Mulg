import Foundation
import CoreGraphics
import QuartzCore
import MulgBridge
import MulgContracts
import Testing
@testable import MulgEngine

@MainActor
final class StartupAudioBridge: NSObject, MacBridge {
    var gameMenus: [[[String: Any]]] = []
    var menuTitle = ""
    var menuAction: ((String) -> Void)?
    func installGameMenu(_ commands: [[String: Any]], title: String, perform: @escaping (String) -> Void) {
        gameMenus.append(commands); menuTitle = title; menuAction = perform
    }
    var configurations = 0, stops = 0
    var requestedRate: Double = 0
    var requestedDepth = 0
    var protected = false
    override init() { super.init() }
    var screenCount: Int { 1 }
    var mainScreenFrame: CGRect { .zero }
    var isMainScreenEqualToFirst: Bool { true }
    var windowFrame: CGRect { .zero }
    var isFullscreen: Bool { false }
    var isWindowVisible: Bool { true }
    var displayMaximumRefreshRate: Int { 60 }
    var displayEDRHeadroom: CGFloat { 1 }
    var isOnBatteryPower: Bool { false }
    var mousePoint: CGPoint { .zero }
    func toggleFullScreen() {}
    func setMenuBarVisible(_ visible: Bool) {}
    func applyWindowPreferences(hideTitleBar: Bool, floating: Bool, aspectWidth: Int, aspectHeight: Int) {}
    func observeDisplayChanges(_ handler: @escaping (Int) -> Void) {}
    func observeWindowVisibility(_ handler: @escaping (Bool) -> Void) {}
    func observePowerSource(_ handler: @escaping (Bool) -> Void) {}
    func observeWindowClosing(_ handler: @escaping () -> Void) {}
    func hideCursor() {}
    func unhideCursor() {}
    func warpCursor() {}
    func hideCursorUntilMouseMoves() {}
    func setupKeyboard(_ handler: @escaping (UInt16, Bool, Bool, UInt) -> Bool) {}
    func setupModifierKeys(_ handler: @escaping (UInt16, Bool, UInt) -> Bool) {}
    func setupMouseMoved(_ handler: @escaping (CGFloat, CGFloat) -> Bool) {}
    func setupMouseButtons(_ handler: @escaping (Int, Bool) -> Bool) {}
    func setupScrollWheel(_ handler: @escaping (CGFloat, CGFloat) -> Bool) {}
    func setupMagnify(_ handler: @escaping (CGFloat, Int) -> Bool) {}
    func setupRotate(_ handler: @escaping (CGFloat, Int) -> Bool) {}
    func setDisplaySyncEnabled(_ enabled: Bool, on layer: CALayer) -> Bool { false }
    func terminateApplication() {}
    func urlForApplication(bundleIdentifier: String) -> URL? { nil }
    func configureAudioOutput(sampleRate: Double, bitDepth: Int, protect: Bool, report: @escaping (NSDictionary) -> Void) {
        configurations += 1; requestedRate = sampleRate; requestedDepth = bitDepth; protected = protect
    }
    func stopAudioOutput(restore: Bool) { stops += 1 }
}

@Suite("Deferred audio startup", .serialized)
@MainActor
struct AudioStartupTests {
    private func context(bridge: StartupAudioBridge, launch: SafeMode.Launch = .normal) -> ModuleContext {
        let paths = ContainerPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        return ModuleContext(bundleIdentifier: "test.audio.startup", paths: paths, settingsStore: SettingsStore(paths: paths),
                             settings: GameSettings(bundleIdentifier: "test.audio.startup"), launch: launch, bridge: bridge)
    }
    @Test func deviceConfigurationWaitsForMainQueueAndKeepsTheRequestedFormat() async {
        let bridge = StartupAudioBridge(), context = context(bridge: bridge)
        let audio = GameAudioOutput(context: context)
        audio.start()
        #expect(bridge.configurations == 0)
        for _ in 0..<100 where bridge.configurations == 0 { await Task.yield() }
        #expect(bridge.configurations == 1)
        #expect(bridge.requestedRate == AudioOutputSettings.iPadSampleRate)
        #expect(bridge.requestedDepth == context.settings.mulg.engine.audioOutput.depth.bits)
        #expect(bridge.protected)
        context.events.publish(GameShutdownFinished())
    }
    @Test func shuttingDownBeforeDeferredWorkDoesNotConfigureHardware() async {
        let bridge = StartupAudioBridge(), context = context(bridge: bridge)
        let audio = GameAudioOutput(context: context)
        audio.start()
        context.events.publish(GameShutdownFinished())
        for _ in 0..<10 { await Task.yield() }
        #expect(bridge.configurations == 0)
        #expect(bridge.stops == 1)
    }
    @Test func minimalRecoveryNeverSchedulesDeviceConfiguration() async {
        let bridge = StartupAudioBridge(), context = context(bridge: bridge, launch: .minimal(unfinishedLaunches: 4))
        let audio = GameAudioOutput(context: context)
        audio.start()
        for _ in 0..<10 { await Task.yield() }
        #expect(bridge.configurations == 0)
    }
}
