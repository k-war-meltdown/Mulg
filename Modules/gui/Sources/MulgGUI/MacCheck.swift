// Host-side module: the Mulg app is a native macOS app, never Mac Catalyst.
#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import Foundation

/// The Mac checks on the welcome assistant and the Home page (PLAN.md §13.3): macOS version,
/// chip, display refresh rate, Low Power Mode and memory.
public struct MacCheck: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let state: ReadinessCheck.State

    public struct Inputs: Sendable, Equatable {
        public var osMajor: Int
        public var appleSilicon: Bool
        public var chip: String
        public var refreshRate: Int
        public var lowPowerMode: Bool
        public var memoryGB: Int

        public init(osMajor: Int, appleSilicon: Bool, chip: String, refreshRate: Int, lowPowerMode: Bool, memoryGB: Int) {
            self.osMajor = osMajor
            self.appleSilicon = appleSilicon
            self.chip = chip
            self.refreshRate = refreshRate
            self.lowPowerMode = lowPowerMode
            self.memoryGB = memoryGB
        }

        /// This Mac right now.
        @MainActor
        public static func current() -> Self {
            #if arch(arm64)
            let appleSilicon = true
            #else
            let appleSilicon = false
            #endif
            let info = ProcessInfo.processInfo
            return Self(
                osMajor: info.operatingSystemVersion.majorVersion,
                appleSilicon: appleSilicon,
                chip: chipName(),
                refreshRate: NSScreen.main?.maximumFramesPerSecond ?? 60,
                lowPowerMode: info.isLowPowerModeEnabled,
                memoryGB: Int(info.physicalMemory >> 30)
            )
        }

        /// "Apple M4 Pro", from the kernel.
        static func chipName() -> String {
            var size = 0
            guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
            var buffer = [UInt8](repeating: 0, count: size)
            guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "Mac" }
            return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    public static func run(_ inputs: Inputs) -> [MacCheck] {
        [
            MacCheck(id: "macOS", title: String(localized: "macOS \(inputs.osMajor)", bundle: .module),
                     detail: inputs.osMajor >= 27
                        ? String(localized: "Golden Gate or later", bundle: .module)
                        : String(localized: "Mulg needs macOS 27 Golden Gate", bundle: .module),
                     state: inputs.osMajor >= 27 ? .ok : .failed),
            MacCheck(id: "chip", title: inputs.chip,
                     detail: inputs.appleSilicon
                        ? String(localized: "Apple silicon runs iPad games natively", bundle: .module)
                        : String(localized: "iPad games need Apple silicon", bundle: .module),
                     state: inputs.appleSilicon ? .ok : .failed),
            MacCheck(id: "display", title: String(localized: "\(inputs.refreshRate) Hz display", bundle: .module),
                     detail: inputs.refreshRate >= 120
                        ? String(localized: "ProMotion: games can run at up to 120 FPS", bundle: .module)
                        : String(localized: "Games run at up to \(inputs.refreshRate) FPS on this display", bundle: .module),
                     state: inputs.refreshRate >= 120 ? .ok : .warning),
            MacCheck(id: "power", title: String(localized: "Low Power Mode", bundle: .module),
                     detail: inputs.lowPowerMode
                        ? String(localized: "On: games are held back. Turn it off in System Settings > Battery.", bundle: .module)
                        : String(localized: "Off: full performance", bundle: .module),
                     state: inputs.lowPowerMode ? .warning : .ok),
            MacCheck(id: "memory", title: String(localized: "\(inputs.memoryGB) GB memory", bundle: .module),
                     detail: inputs.memoryGB >= 16
                        ? String(localized: "Plenty for large games", bundle: .module)
                        : String(localized: "Large games may stutter with less than 16 GB", bundle: .module),
                     state: inputs.memoryGB >= 16 ? .ok : .warning)
        ]
    }
}
#endif
