import Foundation
import MulgContracts
import MulgEngine
import Testing
@testable import MulgDiagnostics

@Suite("Performance writer lifetime", .serialized) @MainActor
struct PerformanceWriterLifetimeTests {
    @Test("The writer sleeps only while requested and cancels on disable, close and release")
    func followsMeasurementLifetime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ContainerPaths(home: root)
        var settings = GameSettings(bundleIdentifier: "writer.lifetime")
        settings.mulg.diagnostics.measureInputLatency = false
        settings.mulg.diagnostics.performanceOverlay = false
        settings.mulg.diagnostics.debugger = false
        let context = ModuleContext(bundleIdentifier: settings.bundleIdentifier, paths: paths,
            settingsStore: SettingsStore(paths: paths), settings: settings, launch: .normal, bridge: nil)
        var module: DiagnosticsModule? = DiagnosticsModule()
        weak var released = module
        try module?.prepare(context)
        #expect(module?.writer == nil)
        module?.activate(context)
        #expect(module?.writer == nil)

        #expect(context.updateSettings { $0.mulg.diagnostics.measureInputLatency = true })
        let first = try #require(module?.writer)
        #expect(!first.isCancelled)
        #expect(context.updateSettings { $0.mulg.diagnostics.measureInputLatency = false })
        #expect(first.isCancelled && module?.writer == nil)

        // An overlay-only request still gets reports; disabling both stops them.
        #expect(context.updateSettings { $0.mulg.diagnostics.performanceOverlay = true })
        let overlay = try #require(module?.writer)
        #expect(context.updateSettings { $0.mulg.diagnostics.measureInputLatency = true })
        #expect(context.updateSettings { $0.mulg.diagnostics.performanceOverlay = false })
        #expect(!overlay.isCancelled)
        context.events.publish(GameClosing())
        #expect(overlay.isCancelled && module?.writer == nil)
        #expect(context.updateSettings { $0.mulg.diagnostics.performanceOverlay = true })
        #expect(module?.writer == nil) // Late settings cannot restart a closing game.
        module = nil
        #expect(released == nil)

        // Releasing an active module cancels its task without waiting for the minute timer.
        module = DiagnosticsModule()
        try module?.prepare(context)
        module?.activate(context)
        let orphan = try #require(module?.writer)
        module = nil
        #expect(orphan.isCancelled)
    }
}
