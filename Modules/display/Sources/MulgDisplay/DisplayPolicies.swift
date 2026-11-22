import Foundation
import MulgContracts

/// The screen the game is shown (PLAN.md §4), from upstream's settings semantics.
public struct ScreenGeometry: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        case off, adaptive, adaptiveInverted, resizable
    }

    public let mode: Mode
    /// Reported screen size in points, already swapped for the inverted mode.
    public let width: Double
    public let height: Double
    /// Upstream's custom scaler.
    public let scale: Double

    public init(mode: Mode, width: Double, height: Double, scale: Double) {
        self.mode = mode
        self.width = width
        self.height = height
        self.scale = scale
    }

    public init(settings: GameSettings) {
        let resolution = ResolutionMode(setting: settings.resolution)
        // Upstream: the inverse fix applies when adaptive display is on (any mode but off).
        let inverted = settings.inverseScreenValues && resolution != .off
        // Every resolution follows the real window (2026-10-10, user request): the game sees the window it draws
        // in, and the render height (1080p, 1440p, 2160p, custom) or exact size is held on top of it. A fixed
        // reported screen next to a different window was the "weird window resolution" and the top-left-quarter
        // mismatch. Only Off (the native screen) and the inverse correction keep a fixed screen.
        let mode: Mode = switch resolution {
        case .off: .off
        case .resizable, .matchDevice, .p2160, .native4K, .native5K, .display: .resizable
        default: settings.inverseScreenValues ? .adaptiveInverted : .resizable
        }
        // The device preset seeds the window at the iPad's point size and pixel scale.
        // Once UIKit has a window, its bounds follow resizing rather than freezing the scene.
        let device = resolution == .matchDevice ? DeviceScreen.forDevice(settings.iosDeviceModel) : nil
        let baseWidth = device?.pointWidth ?? Double(settings.windowWidth)
        let baseHeight = device?.pointHeight ?? Double(settings.windowHeight)
        let width = inverted ? baseHeight : baseWidth
        let height = inverted ? baseWidth : baseHeight
        // Automatic renders the window's own pixels: 0 tells the screen hooks to use the window's real scale,
        // not a render scale left over from another mode.
        let scale = !settings.mulg.display.retina ? 1
            : resolution == .off ? 0
            : mode == .resizable && resolution == .auto ? 0
            : device?.scale ?? resolution.fixedScale ?? (settings.customScaler > 0 ? settings.customScaler : 1)
        self.init(mode: mode, width: width, height: height, scale: scale)
    }
}

/// What to report and how fast the game may draw, for a display and the game's settings
/// (PLAN.md §4.1, §4.2, §6.1).
public struct FrameRatePolicy: Sendable, Equatable {
    /// The refresh rate a real iPad Pro reports.
    public static let iPadProMaximum = 120

    /// UIScreen.maximumFramesPerSecond to report; 0 reports the real value.
    public let reportedMaximum: Int
    /// Target for uncapping and capping; 0 disables both.
    public let target: Int
    public let uncap: Bool
    public let capAtTarget: Bool
    /// Ceiling for independent renderer loops, including caps above the display's refresh.
    public let presentCap: Int
    /// The reported iPad capability exceeds the physical display's visible refresh rate.
    public let proMotionUnavailable: Bool

    /// `onBattery` applies the battery saver cap when the game has it on (§7); `hot` applies the
    /// thermal guard (§13.1).
    public init(displayMaximum: Int, settings: DisplaySettings, onBattery: Bool = false, hot: Bool = false) {
        let supportsProMotion = displayMaximum >= Self.iPadProMaximum
        reportedMaximum = settings.reportProMotion ? Self.iPadProMaximum : 0
        proMotionUnavailable = settings.reportProMotion && !supportsProMotion
        let cap = settings.effectiveFrameRateCap(onBattery: onBattery, hot: hot)
        let belowRefresh = settings.frameCapBelowRefresh ? Self.capTarget(forDisplayMaximum: displayMaximum) : 0
        presentCap = cap > 0 && belowRefresh > 0 ? min(cap, belowRefresh) : max(cap, belowRefresh)
        capAtTarget = settings.frameCapBelowRefresh || cap > 0
        uncap = settings.uncapFrameRate && displayMaximum > 60
        var target = 0
        if settings.frameCapBelowRefresh {
            target = Self.capTarget(forDisplayMaximum: displayMaximum)
        } else if uncap {
            target = displayMaximum
        }
        // A fixed cap is a ceiling on whatever the rules above chose.
        if cap > 0 {
            target = min(target > 0 ? target : displayMaximum, cap)
        }
        self.target = target
    }

    /// Slightly below the refresh rate: 116 at 120 Hz, 140 at 144 Hz, 58 at 60 Hz.
    public static func capTarget(forDisplayMaximum hz: Int) -> Int {
        max(30, hz >= 100 ? hz - 4 : hz - 2)
    }
}
