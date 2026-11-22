import Foundation

/// Upstream's `resolution` setting (stored as an Int in settings files).
public enum ResolutionMode: Int, Sendable, CaseIterable {
    /// No adaptive display: the game sees the real screen.
    case off = 0
    /// Adaptive, sized to the Mac's main screen.
    case auto = 1
    case p1080 = 2
    case p1440 = 3
    case p2160 = 4
    case custom = 5
    /// Resizable window: the game follows the window size.
    case resizable = 6
    /// Exactly the selected device's screen in pixels (2752 × 2064 for the iPad Pro 13-inch); the
    /// window keeps its shape.
    case matchDevice = 7
    /// Exactly 3840 × 2160 render pixels; the window keeps 16:9.
    case native4K = 8
    /// Exactly 5120 × 2880 render pixels; the window keeps 16:9.
    case native5K = 9
    /// The Mac display's own pixels and shape, captured when chosen (`windowWidth` × `customScaler`),
    /// and its refresh rate.
    case display = 10

    public init(setting: Int) {
        self = ResolutionMode(rawValue: setting) ?? .auto
    }

    public var isAdaptive: Bool { [.auto, .p1080, .p1440, .custom].contains(self) }

    /// Fixed pixel height of 1080p, 1440p and 2160p; width follows the game surface. The exact modes use
    /// `GameSettings.fixedRenderSize` (and `targetRenderHeight`) instead. 1080p and 1440p had none, so they only
    /// sized the window and the game rendered at whatever the window was (2026-10-10, user report).
    public var renderHeight: Int? {
        switch self {
        case .p1080: 1080
        case .p1440: 1440
        case .p2160, .native4K: 2160
        case .native5K: 2880
        default: nil
        }
    }

    /// The scale a mode draws at whatever `customScaler` says; nil when the setting decides.
    public var fixedScale: Double? {
        switch self {
        case .native4K, .native5K: 2
        default: nil
        }
    }
}

/// Upstream's `aspectRatio` setting.
public enum AspectRatioChoice: Int, Sendable, CaseIterable {
    case fourByThree = 0
    case sixteenByNine = 1
    case sixteenByTen = 2

    public init(setting: Int) {
        self = AspectRatioChoice(rawValue: setting) ?? .sixteenByNine
    }

    public var ratio: (width: Int, height: Int) {
        switch self {
        case .fourByThree: (4, 3)
        case .sixteenByNine: (16, 9)
        case .sixteenByTen: (16, 10)
        }
    }
}

/// Window-size rules from upstream's settings view (`setResolution`), shared so the app and
/// the runtime agree (PLAN.md §5.5).
public enum ResolutionCalculator {
    /// Upstream warns above this many rendered pixels (width × height × scaler), because games
    /// tend to crash past it (`AppSettingsView.swift:468`).
    public static let pixelWarningThreshold = 2_621_440.0 * 2.0

    /// The window size stored in `windowWidth` / `windowHeight` for a mode.
    public static func windowSize(
        mode: ResolutionMode,
        aspect: AspectRatioChoice,
        mainScreen: (width: Int, height: Int),
        screenHasNotch: Bool,
        custom: (width: Int, height: Int),
        device: DeviceScreen = .recommended
    ) -> (width: Int, height: Int) {
        switch mode {
        case .auto:
            let height = heightAvoidingNotch(width: mainScreen.width, height: mainScreen.height, hasNotch: screenHasNotch)
            return (mainScreen.width, height)
        case .p1080: return (width(forHeight: 1080, aspect: aspect), 1080)
        case .p1440: return (width(forHeight: 1440, aspect: aspect), 1440)
        case .p2160: return (width(forHeight: 2160, aspect: aspect), 2160)
        case .custom: return custom
        case .matchDevice: return (Int(device.pointWidth), Int(device.pointHeight))
        case .native4K: return (1920, 1080)
        case .native5K: return (2560, 1440)
        case .display:
            let height = heightAvoidingNotch(width: mainScreen.width, height: mainScreen.height, hasNotch: screenHasNotch)
            return (mainScreen.width, height)
        case .off, .resizable: return (1920, 1080)
        }
    }

    public static func width(forHeight height: Int, aspect: AspectRatioChoice) -> Int {
        let ratio = aspect.ratio
        return (height / ratio.height) * ratio.width
    }

    /// On notched MacBooks the usable area is 16:10; upstream trims the height to match.
    public static func heightAvoidingNotch(width: Int, height: Int, hasNotch: Bool) -> Int {
        guard hasNotch, width > 0 else { return height }
        let sixteenths = Double(height) / Double(width) * 16
        if sixteenths > 10.3 && sixteenths < 10.4 {
            return Int(Double(width) / 16 * 10)
        }
        return height
    }

    /// Rendered pixels for a window size and scaler.
    public static func pixelLoad(width: Int, height: Int, scaler: Double) -> Double {
        Double(width) * Double(height) * scaler
    }

    public static func exceedsWarning(width: Int, height: Int, scaler: Double) -> Bool {
        pixelLoad(width: width, height: height, scaler: scaler) >= pixelWarningThreshold
    }
}

extension GameSettings {
    /// The exact render size in pixels of the fixed resolutions (iPad screen, 4K, 5K, this display).
    /// The game window keeps this shape, so the game always renders exactly this many pixels.
    public var fixedRenderSize: (width: Int, height: Int)? {
        if !mulg.display.retina {
            // Retina off (display.retina): one pixel per point, like a non-Retina iPad of the same size.
            switch ResolutionMode(setting: resolution) {
            case .matchDevice:
                let device = DeviceScreen.forDevice(iosDeviceModel)
                return (Int(device.pointWidth.rounded()), Int(device.pointHeight.rounded()))
            case .native4K: return (1920, 1080)
            case .native5K: return (2560, 1440)
            case .display:
                guard let width = Self.renderPixels(points: windowWidth, scale: 1),
                      let height = Self.renderPixels(points: windowHeight, scale: 1) else { return nil }
                return (width, height)
            default: return nil
            }
        }
        switch ResolutionMode(setting: resolution) {
        case .matchDevice:
            let device = DeviceScreen.forDevice(iosDeviceModel)
            return (device.pixelWidth, device.pixelHeight)
        case .native4K: return (3840, 2160)
        case .native5K: return (5120, 2880)
        case .display:
            let scale = customScaler.isFinite && customScaler > 0 ? customScaler : 1
            guard let width = Self.renderPixels(points: windowWidth, scale: scale),
                  let height = Self.renderPixels(points: windowHeight, scale: scale) else { return nil }
            return (width, height)
        default: return nil
        }
    }

    /// The pixel height the render surface is held at, or nil when the window decides. A custom resolution
    /// renders its height times the render scale (the custom size is in points, as the window is).
    public var targetRenderHeight: Int? {
        // At 1x the pixel height follows the actual view bounds, including after a resize.
        // A saved launch height would instead change the scale when the window changes size.
        if !mulg.display.retina { return nil }
        if let height = fixedRenderSize?.height ?? ResolutionMode(setting: resolution).renderHeight { return height }
        guard ResolutionMode(setting: resolution) == .custom else { return nil }
        let scale = customScaler.isFinite && customScaler > 0 ? customScaler : 1
        return Self.renderPixels(points: windowHeight, scale: scale)
    }

    /// Validate before any integer conversion. A finite saved scale can still overflow
    /// when multiplied by a stale/corrupt dimension. All render adapters support up to 16K.
    private static func renderPixels(points: Int, scale: Double) -> Int? {
        let pixels = (Double(points) * scale).rounded()
        guard pixels.isFinite, pixels >= 1, pixels <= 16384 else { return nil }
        return Int(pixels)
    }
}
