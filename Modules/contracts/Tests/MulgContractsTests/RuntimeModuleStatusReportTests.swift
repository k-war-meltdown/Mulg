import Foundation
import Testing
@testable import MulgContracts

@Suite("Compatibility launch evidence")
struct RuntimeModuleStatusReportTests {
    @Test(arguments: ["prepared", "active", "degraded(\"Some hooks are missing\")"])
    func runningIdentityKeepsItsCoverageEvidence(state: String) {
        let report = RuntimeModuleStatusReport(processIdentifier: 42, safeMode: false,
            modules: [.init(id: "identity", state: state)])
        #expect(report.identityPrepared)
        #expect(!report.identityDisabledByRecovery)
    }

    @Test(arguments: ["offInSafeMode", "switchedOff", "failed(\"active setup failed\")",
        "unavailable(\"active engine missing\")", "coreOnly(\"offInSafeMode\")", "futureState", "degraded"])
    func unpreparedIdentityDoesNotClaimSetup(state: String) {
        let report = RuntimeModuleStatusReport(processIdentifier: 42, safeMode: true,
            modules: [.init(id: "identity", state: state)])
        #expect(!report.identityPrepared)
    }

    @Test func recoveryReportsExplainWhySavedIdentityDidNotRun() throws {
        let data = Data(#"{"processIdentifier":96446,"safeMode":true,"modules":[{"id":"engine","state":"active","prepareMs":2.8},{"id":"identity","state":"offInSafeMode","activateMs":0}],"hooks":[],"runtimeProtocol":5}"#.utf8)
        let report = try JSONDecoder().decode(RuntimeModuleStatusReport.self, from: data)
        #expect(report.identityDisabledByRecovery)
        #expect(report.identityState == "offInSafeMode")
        #expect(report.launchSessionID == nil)
        // The older compatibility file belongs to a different launch and must be hidden.
        #expect(!report.matches(processIdentifier: 33025, launchSessionID: nil))
        #expect(report.matches(processIdentifier: 96446, launchSessionID: nil))
    }

    @Test func pidReuseAndPartiallyPublishedFilesDoNotMixLaunches() {
        let session = UUID()
        let report = RuntimeModuleStatusReport(processIdentifier: 42, launchSessionID: session,
            safeMode: false, modules: [.init(id: "identity", state: "active")])
        #expect(report.matches(processIdentifier: 42, launchSessionID: session))
        #expect(!report.matches(processIdentifier: 42, launchSessionID: UUID()))
        #expect(!report.matches(processIdentifier: 43, launchSessionID: session))
        #expect(!report.matches(processIdentifier: 42, launchSessionID: nil))
        let legacy = RuntimeModuleStatusReport(processIdentifier: 42, safeMode: false, modules: [])
        #expect(!legacy.matches(processIdentifier: 42, launchSessionID: session))
        #expect(!legacy.identityDisabledByRecovery)
        #expect(legacy.identityState == nil)
        #expect(!legacy.identityPrepared)
    }

    @Test func settingsAndIdentityCarryTheSameSessionMarker() throws {
        let session = UUID()
        let settings = GameSettings(bundleIdentifier: "example.game")
        let runtime = RuntimeSettingsReport(processIdentifier: 42, launch: settings,
            acknowledged: settings, launchSessionID: session)
        let decoded = try JSONDecoder().decode(RuntimeSettingsReport.self, from: JSONEncoder().encode(runtime))
        #expect(decoded.launchSessionID == session)
        let identity = EnvironmentBypassReport(processIdentifier: 42, launchStartedAt: .now,
            bundleIdentifier: "example.game", deviceIdentifier: "iPad17,3", enabled: true,
            deviceRecognized: true, knownSDKChecksRequested: true, installedSDKChecks: 0,
            availableSDKChecks: 58, launchSessionID: session)
        let restored = try JSONDecoder().decode(EnvironmentBypassReport.self, from: JSONEncoder().encode(identity))
        #expect(restored == identity)
        let legacy = RuntimeSettingsReport(processIdentifier: 42, launch: settings, acknowledged: settings)
        let old = try JSONDecoder().decode(RuntimeSettingsReport.self, from: JSONEncoder().encode(legacy))
        #expect(old.launchSessionID == nil)
    }
}
