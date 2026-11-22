import Foundation

/// CPU/RAM variants within a model identifier. Stored independently from the machine ID;
/// this does not report storage capacity or change the physical Mac's capabilities.
public enum MobileDeviceConfiguration: String, Codable, CaseIterable, Sendable, Identifiable {
    case standard
    case highCapacity
    public var id: String { rawValue }
}

/// A device the game can be told it is running on (PLAN.md §3).
public struct MobileDeviceProfile: Sendable, Hashable, Identifiable {
    public enum Family: String, Sendable {
        case iPad, iPhone
    }

    /// Machine identifier reported as `hw.machine`, for example "iPad17,3".
    public let id: String
    public let family: Family
    public let name: String
    public let chip: String
    private let standardMemoryLabel: String
    public let configuration: MobileDeviceConfiguration
    public var memoryLabel: String {
        configuration == .highCapacity ? "16GB" : standardMemoryLabel
    }
    /// Board ID reported as `hw.model` and `hw.target` on a real device, for example "J820AP".
    public let boardID: String
    /// Whether `boardID` has been checked against a real device (PLAN.md §3.2).
    /// Unchecked values come from public device databases.
    public let boardIDVerified: Bool
    /// The SoC's platform name, for example "t8142" for the M5. MobileGestalt's HardwarePlatform
    /// reports it, and the kernel version ends with it in capitals ("RELEASE_ARM64_T8142").
    public let platform: String
    /// Highest refresh rate of the device's own display, in Hz.
    public let maximumRefreshRate: Int

    public init(id: String, family: Family, name: String, chip: String, memoryLabel: String,
                boardID: String, boardIDVerified: Bool, platform: String, maximumRefreshRate: Int,
                configuration: MobileDeviceConfiguration = .standard) {
        self.id = id
        self.family = family
        self.name = name
        self.chip = chip
        self.standardMemoryLabel = memoryLabel
        self.configuration = family == .iPad && (chip == "M4" || chip == "M5") ? configuration : .standard
        self.boardID = boardID
        self.boardIDVerified = boardIDVerified
        self.platform = platform
        self.maximumRefreshRate = maximumRefreshRate
    }

    public var supportsConfigurations: Bool {
        family == .iPad && (chip == "M4" || chip == "M5")
    }

    /// Both processes resolve the same complete variant. Unsupported selections keep
    /// the model's ordinary profile; a saved preference is not lost when switching models.
    public func configured(_ configuration: MobileDeviceConfiguration) -> Self {
        Self(id: id, family: family, name: name, chip: chip, memoryLabel: standardMemoryLabel,
             boardID: boardID, boardIDVerified: boardIDVerified, platform: platform,
             maximumRefreshRate: maximumRefreshRate, configuration: configuration)
    }

    /// Label for the device picker, in upstream's "name | chip | memory" format.
    public var pickerLabel: String {
        "\(name) | \(chip) | \(memoryLabel)"
    }

    public var hasProMotion: Bool {
        maximumRefreshRate >= 120
    }

    /// RAM in bytes, from the picker label ("12GB").
    public var memoryBytes: UInt64 {
        let gigabytes = UInt64(memoryLabel.prefix { $0.isNumber }) ?? 0
        return gigabytes * 1_073_741_824
    }

    /// `MTLDevice.name` on the device, in Apple's "Apple M4 GPU" pattern. Spec sheets name the
    /// M5's GPU "Apple M5 GPU"; the Metal string itself is still to be read on a real device.
    public var gpuName: String {
        "Apple \(chip) GPU"
    }

    /// What `UIDevice.name` returns to apps on the device.
    public var genericName: String {
        family.rawValue
    }

    /// UIKit's mobile HUD idiom, separate from window/render geometry. Apple's SDK
    /// defines phone = 0 and pad = 1; native Mac UI callers retain their actual value.
    public var interfaceIdiom: Int32 { family == .iPad ? 1 : 0 }

    /// The CPU the device reports, or nil when its topology isn't known.
    public var cpu: MobileCPUTopology? {
        guard let standard = MobileDeviceCatalog.cpus[chip] else { return nil }
        // Apple specifies 4 + 6 cores for 1/2 TB M4 and M5 iPads, versus 3 + 6
        // in their standard configurations. CPU family/subfamily remain the same.
        guard configuration == .highCapacity else { return standard }
        return MobileCPUTopology(performanceCores: 4, efficiencyCores: standard.efficiencyCores,
                                 family: standard.family, subfamily: standard.subfamily)
    }

    /// The device's own screen (2752 × 2064 at 2× for the iPad Pro 13-inch M5).
    public var screen: DeviceScreen {
        DeviceScreen.forDevice(id)
    }

    /// Where the answers built from this profile would disagree with each other (PLAN.md §3.7):
    /// model, board ID, SoC, CPU, memory and screen must all describe the same device. Empty
    /// for a consistent profile.
    public var inconsistencies: [String] {
        var found: [String] = []
        if !id.hasPrefix(family.rawValue) { found.append("\(id) is not an \(family.rawValue) identifier") }
        if !boardID.hasSuffix("AP") || boardID.hasPrefix("A") { found.append("\(boardID) is not a board ID") }
        // The ChipID answer and the kernel version are built from "t" or "s" plus four hex digits.
        if platform.count != 5 || !"ts".contains(platform.prefix(1)) || UInt32(platform.dropFirst(), radix: 16) == nil {
            found.append("\(platform) is not an SoC platform name")
        }
        if let other = MobileDeviceCatalog.all.first(where: { $0.chip == chip && $0.platform != platform }) {
            found.append("\(other.id) has the same \(chip) chip but platform \(other.platform)")
        }
        if cpu == nil { found.append("no CPU topology for \(chip), so the Mac's cores show") }
        if memoryBytes == 0 { found.append("no memory size in \(memoryLabel)") }
        if DeviceScreen.byDevice[id] == nil { found.append("no screen for \(id)") }
        return found
    }
}

/// Every device the identity module can present, plus the fallback order (PLAN.md §3.2–3.5).
public enum MobileDeviceCatalog {
    /// iPad Pro 13-inch (M5), Wi-Fi. A Wi-Fi model avoids games probing telephony APIs.
    public static let recommendedDefault = "iPad17,3"

    /// Upstream's default, kept so existing settings behave the same.
    public static let upstreamDefault = "iPad13,8"

    /// Newest to oldest. When a game doesn't recognise one, try the next (§3.5).
    public static let fallbackChain: [String] = ["iPad17,3", "iPad16,5", "iPad14,5", "iPad13,8"]

    public static let all: [MobileDeviceProfile] = [
        // Existing upstream entries; the board IDs of the first three come from upstream.
        ipad("iPad6,7", "iPad Pro (12.9-inch) (1st gen)", "A9X", "4GB", "J98aAP", "s8001", verified: true, hz: 60),
        ipad("iPad8,6", "iPad Pro (12.9-inch) (3rd gen)", "A12X", "4GB", "J320xAP", "t8027", verified: true, hz: 120),
        ipad("iPad13,8", "iPad Pro (12.9-inch) (5th gen)", "M1", "8GB", "J522AP", "t8103", verified: true, hz: 120),
        // Upstream reported marketing model numbers (A2436, A2925) here; these are board IDs (§3.3).
        ipad("iPad14,5", "iPad Pro (12.9-inch) (6th gen)", "M2", "8GB", "J620AP", "t8112", verified: false, hz: 120),
        ipad("iPad16,5", "iPad Pro (13-inch) (M4)", "M4", "8GB", "J720AP", "t8132", verified: false, hz: 120),
        ipad("iPad16,6", "iPad Pro (13-inch) (M4) Wi-Fi + Cellular", "M4", "8GB", "J721AP", "t8132", verified: false, hz: 120),
        // M5 (October 2025), §3.2. Identifier, board ID and platform match Apple's firmware
        // manifests (ipsw.me, AppleDB; checked 2026-09-26); 12 GB is the 256/512 GB model's RAM
        // (Apple's tech specs). Still to be read on a real device, so `verified` stays false.
        ipad("iPad17,1", "iPad Pro (11-inch) (M5)", "M5", "12GB", "J817AP", "t8142", verified: false, hz: 120),
        ipad("iPad17,2", "iPad Pro (11-inch) (M5) Wi-Fi + Cellular", "M5", "12GB", "J818AP", "t8142", verified: false, hz: 120),
        ipad("iPad17,3", "iPad Pro (13-inch) (M5)", "M5", "12GB", "J820AP", "t8142", verified: false, hz: 120),
        ipad("iPad17,4", "iPad Pro (13-inch) (M5) Wi-Fi + Cellular", "M5", "12GB", "J821AP", "t8142", verified: false, hz: 120),
        // iPhones: upstream reported model numbers; these are board IDs (§3.3).
        iphone("iPhone14,3", "iPhone 13 Pro Max", "A15", "6GB", "D64AP", "t8110"),
        iphone("iPhone15,3", "iPhone 14 Pro Max", "A16", "6GB", "D74AP", "t8120"),
        iphone("iPhone16,2", "iPhone 15 Pro Max", "A17 Pro", "8GB", "D84AP", "t8130"),
        iphone("iPhone17,2", "iPhone 16 Pro Max", "A18 Pro", "8GB", "D94AP", "t8140")
    ]

    public static func profile(for identifier: String) -> MobileDeviceProfile? {
        all.first { $0.id == identifier }
    }

    public static func profile(for identifier: String, configuration: MobileDeviceConfiguration) -> MobileDeviceProfile? {
        profile(for: identifier)?.configured(configuration)
    }

    /// The next identifier to try after `identifier` in the fallback chain, if any.
    public static func nextFallback(after identifier: String) -> String? {
        guard let index = fallbackChain.firstIndex(of: identifier) else {
            return fallbackChain.first
        }
        let next = fallbackChain.index(after: index)
        return next < fallbackChain.endIndex ? fallbackChain[next] : nil
    }

    private static func ipad(
        _ id: String, _ name: String, _ chip: String, _ memory: String,
        _ board: String, _ platform: String, verified: Bool, hz: Int
    ) -> MobileDeviceProfile {
        MobileDeviceProfile(id: id, family: .iPad, name: name, chip: chip, memoryLabel: memory,
                      boardID: board, boardIDVerified: verified, platform: platform, maximumRefreshRate: hz)
    }

    private static func iphone(
        _ id: String, _ name: String, _ chip: String, _ memory: String, _ board: String, _ platform: String
    ) -> MobileDeviceProfile {
        MobileDeviceProfile(id: id, family: .iPhone, name: name, chip: chip, memoryLabel: memory,
                      boardID: board, boardIDVerified: false, platform: platform, maximumRefreshRate: 120)
    }
}

extension MobileDeviceCatalog {
    /// `machdep.cpu.brand_string` on iPadOS. XNU reports the device tree's
    /// `product-soc-name` when it has one (a Mac's "Apple M5") and otherwise "<vendor> processor"
    /// (bsd/dev/arm64/sysctl.c). iPads are not known to carry that name; check on a real device (§3.2).
    public static let cpuBrandString = "Apple processor"
}

/// A device's CPU as the kernel reports it (PLAN.md §3.7).
public struct MobileCPUTopology: Sendable, Hashable {
    /// Cores in the fastest level (hw.perflevel0) and in the efficiency level (hw.perflevel1).
    public let performanceCores: UInt32
    public let efficiencyCores: UInt32
    /// XNU's hw.cpufamily and hw.cpusubfamily.
    public let family: UInt32
    public let subfamily: UInt32

    public init(performanceCores: UInt32, efficiencyCores: UInt32, family: UInt32, subfamily: UInt32) {
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
        self.family = family
        self.subfamily = subfamily
    }

    public var totalCores: UInt32 {
        performanceCores + efficiencyCores
    }
}

extension MobileDeviceCatalog {
    /// Core counts are the catalog models' (the 256/512 GB iPads: 9-core M4 and M5). Families come
    /// from macOS's own PMU tables, named by cputype, subtype and family (github.com/jiegec/apple-pmu),
    /// and M5 = 0x1d5a87e8 matches a real M5 MacBook Air. Subfamily 2 (CPUSUBFAMILY_ARM_HG) is what
    /// base M chips report (M1 read on a Mac); 1 (CPUSUBFAMILY_ARM_HP) is the phone chips'.
    static let cpus: [String: MobileCPUTopology] = [
        "A12X": MobileCPUTopology(performanceCores: 4, efficiencyCores: 4, family: 0x07d3_4b9f, subfamily: 0),
        "M1": MobileCPUTopology(performanceCores: 4, efficiencyCores: 4, family: 0x1b58_8bb3, subfamily: 2),
        "M2": MobileCPUTopology(performanceCores: 4, efficiencyCores: 4, family: 0xda33_d83d, subfamily: 2),
        "M4": MobileCPUTopology(performanceCores: 3, efficiencyCores: 6, family: 0x6f51_29ac, subfamily: 2),
        "M5": MobileCPUTopology(performanceCores: 3, efficiencyCores: 6, family: 0x1d5a_87e8, subfamily: 2),
        "A15": MobileCPUTopology(performanceCores: 2, efficiencyCores: 4, family: 0xda33_d83d, subfamily: 1),
        "A16": MobileCPUTopology(performanceCores: 2, efficiencyCores: 4, family: 0x8765_edea, subfamily: 1),
        "A17 Pro": MobileCPUTopology(performanceCores: 2, efficiencyCores: 4, family: 0x2876_f5b5, subfamily: 1),
        "A18 Pro": MobileCPUTopology(performanceCores: 2, efficiencyCores: 4, family: 0x75d4_acb9, subfamily: 1)
    ]
}
