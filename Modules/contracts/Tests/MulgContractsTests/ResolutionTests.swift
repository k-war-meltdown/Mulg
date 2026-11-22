import Testing
@testable import MulgContracts

@Suite("ResolutionCalculator")
struct ResolutionTests {
    @Test("Fixed presets derive the width from the aspect ratio, like upstream")
    func presets() {
        let size = ResolutionCalculator.windowSize(
            mode: .p1440, aspect: .sixteenByTen, mainScreen: (3024, 1964), screenHasNotch: false, custom: (0, 0))
        #expect(size.width == 2304 && size.height == 1440)
        let fourK = ResolutionCalculator.windowSize(
            mode: .p2160, aspect: .sixteenByNine, mainScreen: (0, 0), screenHasNotch: false, custom: (0, 0))
        #expect(fourK.width == 3840 && fourK.height == 2160)
    }

    @Test("Auto trims a notched 16:10.35 screen to 16:10")
    func notch() {
        // 1512 × 982 is a 14-inch MacBook Pro in its default scaled mode.
        #expect(ResolutionCalculator.heightAvoidingNotch(width: 1512, height: 982, hasNotch: true) == 945)
        #expect(ResolutionCalculator.heightAvoidingNotch(width: 1512, height: 982, hasNotch: false) == 982)
    }

    @Test("The pixel warning matches upstream's threshold")
    func warning() {
        #expect(!ResolutionCalculator.exceedsWarning(width: 2560, height: 1440, scaler: 1.0))
        #expect(ResolutionCalculator.exceedsWarning(width: 3840, height: 2160, scaler: 2.0))
    }

    @Test("iPad, 4K, 5K and This display render exactly their sizes, independent of the window")
    func exactSizes() {
        var settings = GameSettings()
        settings.resolution = ResolutionMode.matchDevice.rawValue
        #expect(settings.fixedRenderSize! == (2752, 2064) && settings.targetRenderHeight == 2064)
        settings.resolution = ResolutionMode.native4K.rawValue
        (settings.windowWidth, settings.windowHeight) = (1500, 900) // any window
        #expect(settings.fixedRenderSize! == (3840, 2160) && settings.targetRenderHeight == 2160)
        settings.resolution = ResolutionMode.native5K.rawValue
        #expect(settings.fixedRenderSize! == (5120, 2880))
        // This display: the monitor's points (notch area left out) at its backing scale.
        settings.resolution = ResolutionMode.display.rawValue
        let window = ResolutionCalculator.windowSize(mode: .display, aspect: .sixteenByNine, mainScreen: (1512, 982),
                                                     screenHasNotch: true, custom: (0, 0))
        (settings.windowWidth, settings.windowHeight) = window
        settings.customScaler = 2
        #expect(settings.fixedRenderSize! == (3024, 1890))
        #expect(ResolutionMode(setting: 10) == .display && !ResolutionMode.display.isAdaptive)
        settings.resolution = ResolutionMode.p2160.rawValue
        #expect(settings.fixedRenderSize == nil && settings.targetRenderHeight == 2160)
        // 1080p and 1440p render that many pixels tall whatever the window (they used to size the window only).
        settings.resolution = ResolutionMode.p1080.rawValue
        #expect(settings.fixedRenderSize == nil && settings.targetRenderHeight == 1080)
        settings.resolution = ResolutionMode.p1440.rawValue
        #expect(settings.targetRenderHeight == 1440)
        // Custom: its height (points) times the render scale.
        settings.resolution = ResolutionMode.custom.rawValue
        (settings.windowWidth, settings.windowHeight, settings.customScaler) = (1600, 900, 1.5)
        #expect(settings.targetRenderHeight == 1350)
        settings.resolution = ResolutionMode.auto.rawValue
        #expect(settings.targetRenderHeight == nil)
        settings.resolution = ResolutionMode.resizable.rawValue
        #expect(settings.targetRenderHeight == nil)
    }

    @Test("Unknown stored values fall back to safe modes")
    func unknownValues() {
        #expect(ResolutionMode(setting: 42) == .auto)
        #expect(AspectRatioChoice(setting: -1) == .sixteenByNine)
    }
}
