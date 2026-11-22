import Foundation
import Testing
@testable import MulgContracts

@Suite("Desktop 120 FPS installation policy")
struct DesktopPerformanceDefaultsTests {
    @Test func replacesSavingAndDownscalingWithoutResettingOtherFeatures() {
        var settings=GameSettings(bundleIdentifier:"com.test.desktop")
        settings.resolution=ResolutionMode.p1080.rawValue
        settings.mulg.display.uncapFrameRate=false
        settings.mulg.display.frameRateCap=30
        settings.mulg.display.frameCapBelowRefresh=true
        settings.mulg.display.backgroundThrottle=true
        settings.mulg.display.batterySaverOnBattery=true
        settings.mulg.display.thermalGuard=true
        settings.mulg.graphics.metalFX.enabled=true
        settings.mulg.graphics.metalFX.automatic=true
        settings.mulg.graphics.fullScreenPerformanceMode=true
        settings.mulg.graphics.fullResolution=false
        settings.mulg.graphics.forceRenderResolution=false
        settings.sensitivity=81
        settings.mulg.controls.gyro.source = .mouse
        settings.mulg.privacy.camera=true
        settings.mulg.engine.disabledModules=["identity"]
        let controls=settings.mulg.controls, engine=settings.mulg.engine, identity=settings.mulg.identity
        DesktopPerformanceDefaults.apply(to:&settings,desktop:(1920,1200,2))
        #expect(settings.resolution==ResolutionMode.display.rawValue)
        #expect(settings.fixedRenderSize?.width==3840 && settings.fixedRenderSize?.height==2400)
        #expect(settings.mulg.display.effectiveFrameRateCap(onBattery:true,hot:true)==120)
        #expect(settings.mulg.display.uncapFrameRate && !settings.mulg.display.frameCapBelowRefresh)
        #expect(!settings.mulg.display.backgroundThrottle && !settings.mulg.display.batterySaverOnBattery && !settings.mulg.display.thermalGuard)
        #expect(!settings.mulg.graphics.metalFX.enabled && !settings.mulg.graphics.metalFX.automatic)
        #expect(!settings.mulg.graphics.fullScreenPerformanceMode && settings.mulg.graphics.fullResolution && settings.mulg.graphics.forceRenderResolution)
        #expect(settings.sensitivity==81 && settings.mulg.privacy.camera)
        #expect(settings.mulg.controls==controls && settings.mulg.engine==engine && settings.mulg.identity==identity)
        let once=settings
        DesktopPerformanceDefaults.apply(to:&settings,desktop:(1920,1200,2))
        #expect(settings==once)
    }

    @Test func headlessOrInvalidDesktopKeepsExistingGeometry() {
        for desktop: (Int,Int,Double)? in [nil,(0,900,2),(1440,-1,2),(1440,900,.nan)] {
            var settings=GameSettings()
            settings.windowWidth=1600;settings.windowHeight=1000;settings.customScaler=2
            DesktopPerformanceDefaults.apply(to:&settings,desktop:desktop)
            #expect(settings.fixedRenderSize?.width==3200 && settings.fixedRenderSize?.height==2000)
            #expect(settings.mulg.display.frameRateCap==120)
        }
    }
}