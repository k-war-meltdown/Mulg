import Foundation
import Testing
@testable import MulgContracts

@Suite("Compatibility report versions")
struct EnvironmentBypassReportTests {
    @Test func olderReportsRemainReadableWithoutIdentityCoverage() throws {
        let data = Data(#"{"processIdentifier":42,"launchStartedAt":0,"bundleIdentifier":"game.example","deviceIdentifier":"iPad17,3","enabled":true,"deviceRecognized":true,"knownSDKChecksRequested":true,"installedSDKChecks":0,"availableSDKChecks":58}"#.utf8)
        let report = try JSONDecoder().decode(EnvironmentBypassReport.self, from: data)
        #expect(report.processIdentifier == 42)
        #expect(report.installedSDKChecks == 0)
        #expect(report.mobileUIHooksInstalled == nil)
        #expect(report.identityAudit == nil)
        #expect(report.launchSessionID == nil)
    }

    @Test func partialCoverageAndUnverifiedHardwareSurviveTheReportBoundary() throws {
        let audit = DeviceIdentityAudit(profileName: "Selected iPad", boardIdentifier: "J820AP",
            hardwarePlatform: "t8142", cpuCores: 9, memoryLimitBytes: 12 * 1_073_741_824,
            reportedMemoryBytes: 8 * 1_073_741_824, configured: true, gameOnlyAnswers: true,
            boardVerified: false, hooks: [.init(id: "idiom", title: "Mobile interface", installed: 1, expected: 2)],
            warnings: ["Memory is not overstated."],
            signals: [.init(id: "machine", title: "Machine", expected: "iPad17,3", configured: "iPad13,8")],
            deviceConfiguration: .highCapacity)
        let report = EnvironmentBypassReport(processIdentifier: 42, launchStartedAt: Date(timeIntervalSince1970: 1_700_000_000),
            bundleIdentifier: "game.example", deviceIdentifier: "iPad17,3", enabled: true, deviceRecognized: true,
            knownSDKChecksRequested: true, installedSDKChecks: 0, availableSDKChecks: 58,
            mobileUIHooksInstalled: 1, identityAudit: audit)
        let decoded = try JSONDecoder().decode(EnvironmentBypassReport.self, from: JSONEncoder().encode(report))
        #expect(decoded == report)
        #expect(decoded.identityAudit?.hasMissingHooks == true)
        #expect(decoded.identityAudit?.hasMismatchedSignals == true)
        #expect(decoded.identityAudit?.boardVerified == false)
        #expect(decoded.identityAudit?.deviceConfiguration == .highCapacity)
        #expect(decoded.installedSDKChecks == 0)
    }

    @Test func auditsFromBeforeSignalComparisonsRemainReadable() throws {
        let data = Data(#"{"profileName":"Selected iPad","boardIdentifier":"J820AP","hardwarePlatform":"t8142","memoryLimitBytes":12884901888,"reportedMemoryBytes":8589934592,"configured":true,"gameOnlyAnswers":true,"boardVerified":false,"hooks":[],"warnings":[]}"#.utf8)
        let audit = try JSONDecoder().decode(DeviceIdentityAudit.self, from: data)
        #expect(audit.signals == nil)
        #expect(audit.deviceConfiguration == nil)
        #expect(audit.cpuCores == nil)
        #expect(!audit.hasMismatchedSignals)
    }

    @Test func stalePIDReuseCannotMakeAnOldReportCurrent() {
        let report = EnvironmentBypassReport(processIdentifier: 42,
            launchStartedAt: Date(timeIntervalSince1970: 1_700_000_010),
            bundleIdentifier: "game.example", deviceIdentifier: "iPad17,3", enabled: true,
            deviceRecognized: true, knownSDKChecksRequested: true,
            installedSDKChecks: 0, availableSDKChecks: 58)
        #expect(report.belongsToLaunch(bundleIdentifier: "game.example", processIdentifier: 42,
            processLaunchDate: Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(!report.belongsToLaunch(bundleIdentifier: "game.example", processIdentifier: 42,
            processLaunchDate: Date(timeIntervalSince1970: 1_700_000_020)))
        #expect(!report.belongsToLaunch(bundleIdentifier: "other.example", processIdentifier: 42,
            processLaunchDate: Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(!report.belongsToLaunch(bundleIdentifier: "game.example", processIdentifier: 43,
            processLaunchDate: Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(!report.belongsToLaunch(bundleIdentifier: "game.example", processIdentifier: 42,
            processLaunchDate: nil))
    }
}
