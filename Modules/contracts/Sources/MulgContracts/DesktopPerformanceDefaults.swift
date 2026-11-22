import Foundation

/// Shared installation policy. The host supplies desktop geometry; contracts stay platform-neutral.
public enum DesktopPerformanceDefaults {
    public static func apply(to settings: inout GameSettings,
                             desktop: (width: Int, height: Int, scale: Double)? = nil) {
        settings.resolution = ResolutionMode.display.rawValue
        if let desktop, desktop.width > 0, desktop.height > 0,
           desktop.scale.isFinite, desktop.scale > 0 {
            settings.windowWidth = desktop.width
            settings.windowHeight = desktop.height
            settings.customScaler = desktop.scale
        }
        settings.mulg.display.reportProMotion = true
        settings.mulg.display.uncapFrameRate = true
        settings.mulg.display.frameRateCap = 120
        settings.mulg.display.frameCapBelowRefresh = false
        settings.mulg.display.backgroundThrottle = false
        settings.mulg.display.batterySaverOnBattery = false
        settings.mulg.display.thermalGuard = false
        settings.mulg.graphics.metalFX.enabled = false
        settings.mulg.graphics.metalFX.automatic = false
        settings.mulg.graphics.fullScreenPerformanceMode = false
        settings.mulg.graphics.fullResolution = true
        settings.mulg.graphics.forceRenderResolution = true
    }
}