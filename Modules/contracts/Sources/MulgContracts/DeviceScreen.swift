import Foundation

/// The built-in screen of a device the game can be told it runs on, so the screen the game
/// sees matches the model it is told (PLAN.md §3.7, §5.5). Shared by `identity` (the model)
/// and `display` (the screen), which may not import each other.
public struct DeviceScreen: Sendable, Equatable {
    /// Native pixels, long side first (landscape, as games run on a Mac).
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// `UIScreen.scale` on the device.
    public let scale: Double

    public init(pixelWidth: Int, pixelHeight: Int, scale: Double) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
    }

    /// The size in points, as `UIScreen.bounds` reports it.
    public var pointWidth: Double { Double(pixelWidth) / scale }
    public var pointHeight: Double { Double(pixelHeight) / scale }

    /// iPad Pro 13-inch (M5 and M4): 2752 × 2064 at 2×, 264 ppi, ProMotion up to 120 Hz.
    public static let iPadPro13 = DeviceScreen(pixelWidth: 2752, pixelHeight: 2064, scale: 2)
    /// iPad Pro 11-inch (M5 and M4): 2420 × 1668 at 2×.
    public static let iPadPro11 = DeviceScreen(pixelWidth: 2420, pixelHeight: 1668, scale: 2)
    /// iPad Pro 12.9-inch (every generation): 2732 × 2048 at 2×.
    public static let iPadPro129 = DeviceScreen(pixelWidth: 2732, pixelHeight: 2048, scale: 2)

    /// The screen of the recommended identity, iPad Pro 13-inch (M5).
    public static let recommended = iPadPro13

    public static let byDevice: [String: DeviceScreen] = [
        "iPad17,3": iPadPro13, "iPad17,4": iPadPro13, "iPad16,5": iPadPro13, "iPad16,6": iPadPro13,
        "iPad17,1": iPadPro11, "iPad17,2": iPadPro11,
        "iPad14,5": iPadPro129, "iPad13,8": iPadPro129, "iPad8,6": iPadPro129, "iPad6,7": iPadPro129,
        "iPhone14,3": DeviceScreen(pixelWidth: 2778, pixelHeight: 1284, scale: 3),
        "iPhone15,3": DeviceScreen(pixelWidth: 2796, pixelHeight: 1290, scale: 3),
        "iPhone16,2": DeviceScreen(pixelWidth: 2796, pixelHeight: 1290, scale: 3),
        "iPhone17,2": DeviceScreen(pixelWidth: 2868, pixelHeight: 1320, scale: 3)
    ]

    /// The screen of a device identifier, or the iPad Pro 13-inch (M5) for unknown identifiers.
    public static func forDevice(_ identifier: String) -> DeviceScreen {
        byDevice[identifier] ?? recommended
    }
}
