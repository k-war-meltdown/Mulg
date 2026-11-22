import Foundation
import Testing
@testable import MulgContracts

@Suite("Mobile interface compatibility preferences")
struct MobileInterfaceSettingsTests {
    @Test func oldSettingsKeepNativeInterfaceUnlessTheirPresetAlreadyRequestedIt() throws {
        let ordinary = try JSONDecoder().decode(IdentitySettings.self, from: Data("{}".utf8))
        #expect(!ordinary.matchMobileInterface && !ordinary.effective.matchMobileInterface)
        let preset = try JSONDecoder().decode(IdentitySettings.self,
            from: Data("{\"environmentBypass\":true}".utf8))
        #expect(!preset.matchMobileInterface && preset.effective.matchMobileInterface)
    }

    @Test func independentChoiceSurvivesWithoutEnablingOtherCompatibilityOptions() throws {
        var settings = GameSettings(bundleIdentifier: "example.game")
        settings.mulg.identity.matchMobileInterface = true
        let decoded = try SettingsStore.decode(PropertyListEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(decoded.mulg.identity.effective.matchMobileInterface)
        #expect(!decoded.mulg.identity.environmentBypass && !decoded.bypass)
        #expect(!decoded.mulg.identity.effective.matchDeviceCPU)
        #expect(!decoded.mulg.identity.macAnswers.contains("identity.matchMobileInterface"))
    }

    @Test(arguments: [false, true])
    func presetRestoresTheSavedInterfaceChoice(saved: Bool) {
        var settings = IdentitySettings()
        settings.matchMobileInterface = saved
        settings.environmentBypass = true
        #expect(settings.effective.matchMobileInterface)
        #expect(settings.matchMobileInterface == saved)
        settings.environmentBypass = false
        #expect(settings.effective.matchMobileInterface == saved)
    }

    @Test func catalogUsesMobileFamilyWithoutChangingTheDisplayProfile() throws {
        let pad = try #require(MobileDeviceCatalog.profile(for: "iPad17,3"))
        let phone = try #require(MobileDeviceCatalog.profile(for: "iPhone17,2"))
        #expect(pad.interfaceIdiom == 1 && phone.interfaceIdiom == 0)
        #expect(pad.configured(.highCapacity).interfaceIdiom == pad.interfaceIdiom)
        #expect(pad.configured(.highCapacity).screen == pad.screen)
    }
}
