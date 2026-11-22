import Foundation
import Testing
@testable import MulgContracts

@Suite("Device CPU/RAM configurations")
struct MobileDeviceConfigurationTests {
    @Test func existingProfilesKeepTheirStandardConfiguration() throws {
        let settings = try JSONDecoder().decode(IdentitySettings.self, from: Data("{}".utf8))
        #expect(settings.deviceConfiguration == .standard)
        let profile = try #require(MobileDeviceCatalog.profile(for: "iPad17,3"))
        #expect(profile.memoryBytes == 12 * 1_073_741_824)
        #expect(profile.cpu?.totalCores == 9)
        #expect(profile == MobileDeviceCatalog.profile(for: profile.id, configuration: .standard))
    }

    @Test(arguments: ["iPad17,1", "iPad17,2", "iPad17,3", "iPad17,4", "iPad16,5", "iPad16,6"])
    func highCapacityPairsMemoryWithTheExtraFastCore(identifier: String) throws {
        let standard = try #require(MobileDeviceCatalog.profile(for: identifier))
        let large = try #require(MobileDeviceCatalog.profile(for: identifier, configuration: .highCapacity))
        #expect(large.supportsConfigurations)
        #expect(large.configuration == .highCapacity)
        #expect(large.memoryBytes == 16 * 1_073_741_824)
        #expect(large.cpu?.performanceCores == 4)
        #expect(large.cpu?.efficiencyCores == 6)
        #expect(large.cpu?.totalCores == 10)
        #expect(large.cpu?.family == standard.cpu?.family)
        #expect(large.cpu?.subfamily == standard.cpu?.subfamily)
        #expect(large.id == standard.id && large.boardID == standard.boardID)
        #expect(large.platform == standard.platform && large.screen == standard.screen)
        #expect(large.gpuName == standard.gpuName && large.maximumRefreshRate == standard.maximumRefreshRate)
        #expect(large.configured(.standard) == standard)
        #expect(large.inconsistencies.isEmpty)
    }

    @Test func unsupportedDevicesKeepTheirActualCatalogProfile() throws {
        for identifier in ["iPhone17,2", "iPad13,8", "iPad6,7"] {
            let standard = try #require(MobileDeviceCatalog.profile(for: identifier))
            #expect(!standard.supportsConfigurations)
            #expect(MobileDeviceCatalog.profile(for: identifier, configuration: .highCapacity) == standard)
        }
        #expect(MobileDeviceCatalog.profile(for: "iPad99,9", configuration: .highCapacity) == nil)
    }

    @Test func configurationSurvivesSettingsWithoutEnablingOtherFeatures() throws {
        var settings = GameSettings(bundleIdentifier: "example.game")
        settings.mulg.identity.deviceConfiguration = .highCapacity
        settings.mulg.identity.presentAsIPad = false
        let decoded = try SettingsStore.decode(PropertyListEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(!decoded.mulg.identity.environmentBypass)
        #expect(!decoded.mulg.identity.effective.presentAsIPad)
        #expect(!decoded.mulg.identity.effective.matchDeviceCPU)
        var preset = decoded.mulg.identity
        preset.environmentBypass = true
        #expect(preset.effective.deviceConfiguration == .highCapacity)
        #expect(preset.effective.matchDeviceCPU)
        #expect(!preset.matchDeviceCPU)
    }
}
