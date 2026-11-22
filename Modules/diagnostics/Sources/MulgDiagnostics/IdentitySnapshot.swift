import Foundation
import Metal
#if canImport(UIKit)
import UIKit
#endif
#if canImport(IOKit)
import IOKit
#endif

/// Every device signal a game can compare with the model (PLAN.md §3.7), read the way a game
/// reads it. This is the probe for checking the identity against a real device (§1.5 rule 8):
/// run it in a plain app on a real iPad Pro 13-inch (M5), save `json()`, and compare it line by
/// line with the same call made from that app installed and running under Mulg. The file
/// imports only Apple frameworks so it can be copied into such an app unchanged.
///
/// Call it from outside the Mulg runtime. dyld never applies interposing to the image that
/// interposes, so inside the runtime the C functions (sysctl, uname, MGCopyAnswer) return the
/// Mac's real values; only the Objective-C answers would show what the game sees.
public enum IdentitySnapshot {
    static let sysctlStrings = [
        "hw.machine", "hw.model", "hw.product", "hw.target", "hw.targettype", "machdep.cpu.brand_string",
        "kern.hostname", "kern.version", "kern.osversion", "kern.osproductversion",
        "hw.perflevel0.name", "hw.perflevel1.name"
    ]
    static let sysctlNumbers = [
        "hw.memsize", "hw.ncpu", "hw.physicalcpu", "hw.logicalcpu", "hw.cpufamily", "hw.cpusubfamily", "hw.nperflevels",
        "hw.perflevel0.physicalcpu", "hw.perflevel1.physicalcpu", "machdep.cpu.core_count"
    ]
    /// Plain MobileGestalt keys and the obfuscated forms identity answers (§3.7).
    static let gestaltQuestions = [
        "ProductType", "HWModelStr", "DeviceClass", "DeviceName", "HardwarePlatform", "UserAssignedDeviceName",
        "ChipID", "DeviceClassNumber", "main-screen-width", "main-screen-height", "main-screen-scale",
        "h9jDsbgj7xIVeIQ8S3/X3Q", "/YYygAofPDbhrwToVsXdeA", "+3Uf0Pm5F8Xy7Onyvko0vA"
    ]

    @MainActor
    public static func collect() -> [String: String] {
        var values: [String: String] = [:]
        for name in sysctlStrings {
            values["sysctl." + name] = sysctlString(name)
        }
        for name in sysctlNumbers {
            values["sysctl." + name] = sysctlNumber(name).map { String($0) }
        }
        var system = utsname()
        if uname(&system) == 0 {
            values["uname.machine"] = cString(system.machine)
            values["uname.nodename"] = cString(system.nodename)
            values["uname.release"] = cString(system.release)
            values["uname.version"] = cString(system.version)
        }
        for question in gestaltQuestions {
            values["MobileGestalt." + question] = gestalt(question)
        }

        let info = ProcessInfo.processInfo
        values["ProcessInfo.physicalMemory"] = String(info.physicalMemory)
        values["ProcessInfo.activeProcessorCount"] = String(info.activeProcessorCount)
        values["ProcessInfo.processorCount"] = String(info.processorCount)
        values["sysconf.NPROCESSORS_ONLN"] = String(sysconf(_SC_NPROCESSORS_ONLN))
        values["ProcessInfo.isiOSAppOnMac"] = String(info.isiOSAppOnMac)
        values["ProcessInfo.isMacCatalystApp"] = String(info.isMacCatalystApp)
        values["ProcessInfo.isLowPowerModeEnabled"] = String(info.isLowPowerModeEnabled)
        values["ProcessInfo.thermalState"] = String(info.thermalState.rawValue)
        values["ProcessInfo.operatingSystemVersionString"] = info.operatingSystemVersionString
        values["ProcessInfo.hostName"] = info.hostName

        #if canImport(IOKit)
        // The device-tree root; on the Mac only (the iOS SDK has no IOKit module).
        let expert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        if expert != 0 {
            defer { IOObjectRelease(expert) }
            for key in ["model", "compatible", "target-type", "platform-name"] {
                let value = IORegistryEntryCreateCFProperty(expert, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue()
                values["IOPlatformExpertDevice." + key] = (value as? Data).map {
                    String(decoding: $0, as: UTF8.self).split(separator: "\0").joined(separator: " ")
                } ?? value.map { String(describing: $0) }
            }
            // The same names read all at once, the other way a game can ask.
            var all: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(expert, &all, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let properties = all?.takeRetainedValue() as? [String: Any],
               let model = properties["model"] as? Data {
                values["IOPlatformExpertDevice.properties.model"] = String(decoding: model.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
        #endif

        if let device = MTLCreateSystemDefaultDevice() {
            values["MTLDevice.name"] = device.name
            values["MTLDevice.architecture"] = device.architecture.name
            values["MTLDevice.recommendedMaxWorkingSetSize"] = String(device.recommendedMaxWorkingSetSize)
        }

        #if canImport(UIKit) && !os(watchOS)
        let device = UIDevice.current
        values["UIDevice.name"] = device.name
        values["UIDevice.model"] = device.model
        values["UIDevice.localizedModel"] = device.localizedModel
        values["UIDevice.systemName"] = device.systemName
        values["UIDevice.systemVersion"] = device.systemVersion
        values["UIDevice.userInterfaceIdiom"] = String(device.userInterfaceIdiom.rawValue)
        let screen = UIScreen.main
        values["UIScreen.bounds"] = "\(screen.bounds.width)x\(screen.bounds.height)"
        values["UIScreen.nativeBounds"] = "\(screen.nativeBounds.width)x\(screen.nativeBounds.height)"
        values["UIScreen.scale"] = "\(screen.scale)"
        values["UIScreen.nativeScale"] = "\(screen.nativeScale)"
        values["UIScreen.maximumFramesPerSecond"] = String(screen.maximumFramesPerSecond)
        #endif
        return values
    }

    /// `collect()` as sorted, pretty JSON, ready to save and compare.
    @MainActor
    public static func json() -> String {
        let data = (try? JSONSerialization.data(withJSONObject: collect(), options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// 4- and 8-byte integers alike: the value lands in the low bytes (arm64 is little-endian).
    static func sysctlNumber(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    private typealias CopyAnswer = @convention(c) (CFString, CFDictionary?) -> Unmanaged<CFTypeRef>?

    /// MobileGestalt is private, so it is looked up at run time rather than linked.
    static func gestalt(_ question: String) -> String? {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        guard let symbol = dlsym(defaultHandle, "MGCopyAnswer") else { return nil }
        let copyAnswer = unsafeBitCast(symbol, to: CopyAnswer.self)
        guard let answer = copyAnswer(question as CFString, nil)?.takeRetainedValue() else { return nil }
        return answer as? String ?? String(describing: answer)
    }
}
