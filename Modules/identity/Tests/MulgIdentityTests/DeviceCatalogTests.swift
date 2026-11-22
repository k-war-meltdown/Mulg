import Foundation
import Testing
import MulgContracts
import MulgIdentityHooks
@testable import MulgIdentity

@Suite("DeviceCatalog")
struct DeviceCatalogTests {
    @Test("Host and runtime use the same catalog without changing the identity API")
    func sharedCatalog() {
        #expect(DeviceCatalog.all == MobileDeviceCatalog.all)
        #expect(DeviceCatalog.recommendedDefault == MobileDeviceCatalog.recommendedDefault)
        #expect(DeviceCatalog.all.map(\.cpu) == MobileDeviceCatalog.all.map(\.cpu))
        #expect(DeviceCatalog.profile(for: "iPad17,3", configuration: .highCapacity)
            == MobileDeviceCatalog.profile(for: "iPad17,3", configuration: .highCapacity))
    }

    @Test("The M5 iPad Pro models are in the catalog with their board IDs",
          arguments: [("iPad17,1", "J817AP"), ("iPad17,2", "J818AP"),
                      ("iPad17,3", "J820AP"), ("iPad17,4", "J821AP")])
    func m5Models(identifier: String, board: String) throws {
        let profile = try #require(DeviceCatalog.profile(for: identifier))
        #expect(profile.boardID == board)
        #expect(profile.chip == "M5")
        #expect(profile.hasProMotion)
    }

    @Test("The recommended default is the 13-inch M5 Wi-Fi model")
    func recommendedDefault() throws {
        let profile = try #require(DeviceCatalog.profile(for: DeviceCatalog.recommendedDefault))
        #expect(profile.id == "iPad17,3")
        #expect(profile.pickerLabel == "iPad Pro (13-inch) (M5) | M5 | 12GB")
    }

    @Test("Every board ID looks like a real board ID, never a marketing model number (§3.3)")
    func boardIDsAreBoardIDs() {
        for profile in DeviceCatalog.all {
            #expect(profile.boardID.hasSuffix("AP"), "\(profile.id) reports \(profile.boardID)")
            #expect(!profile.boardID.hasPrefix("A"), "\(profile.id) reports a model number")
        }
    }

    @Test("Identifiers are unique")
    func uniqueIdentifiers() {
        let ids = DeviceCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Upstream's device list is still offered, so existing settings keep working")
    func upstreamDevicesKept() {
        for id in ["iPad6,7", "iPad8,6", "iPad13,8", "iPad14,5", "iPad16,6",
                   "iPhone14,3", "iPhone15,3", "iPhone16,2", "iPhone17,2"] {
            #expect(DeviceCatalog.profile(for: id) != nil, "\(id) missing")
        }
    }

    @Test("The fallback chain goes M5, M4, M2, M1 and every step is in the catalog")
    func fallbackChain() {
        #expect(DeviceCatalog.fallbackChain == ["iPad17,3", "iPad16,5", "iPad14,5", "iPad13,8"])
        for id in DeviceCatalog.fallbackChain {
            #expect(DeviceCatalog.profile(for: id) != nil)
        }
        #expect(DeviceCatalog.nextFallback(after: "iPad17,3") == "iPad16,5")
        #expect(DeviceCatalog.nextFallback(after: "iPad13,8") == nil)
        #expect(DeviceCatalog.nextFallback(after: "iPhone16,2") == "iPad17,3")
    }
}

@Suite("IdentityModule")
struct IdentityModuleTests {
    @Test("A catalog device gives its identifier and board ID")
    func knownDevice() {
        var settings = GameSettings()
        settings.iosDeviceModel = "iPad17,3"
        #expect(IdentityConfiguration(settings: settings)
            == IdentityConfiguration(machine: "iPad17,3", boardID: "J820AP"))
    }

    @Test("An unknown identifier is never reported with a made-up board ID")
    func unknownDevice() {
        var settings = GameSettings()
        settings.iosDeviceModel = "iPad99,9"
        #expect(IdentityConfiguration(settings: settings) == nil)
    }
}

/// Stands in for an SDK's jailbreak check (DTTJailbreakDetection is in the bypass list).
@objc(DTTJailbreakDetection)
private final class FakeJailbreakDetection: NSObject {
    @objc dynamic class func isJailbroken() -> Bool { true }
}

/// An SDK version whose `getDeviceType` returns an object, where the bypass table answers the number 1:
/// replacing it would hand the game the pointer 0x1.
@objc(RNDeviceInfo)
private final class FakeChangedDeviceInfo: NSObject {
    @objc dynamic func getDeviceType() -> NSString { "Tablet" }
}

@Suite("Jailbreak bypass")
struct JailbreakBypassTests {
    @Test("Upstream's whole jailbreak-check list is present")
    func entries() {
        // Upstream's compatibility file installs 58 SDK replacements (3 device-info, 55 jailbreak checks).
        #expect(mulg_identity_jailbreak_bypass_entry_count() == 58)
    }

    @Test("A known SDK check answers not jailbroken once installed")
    func answersNo() {
        #expect(FakeJailbreakDetection.isJailbroken())
        #expect(mulg_identity_install_jailbreak_bypass() >= 1)
        #expect(!FakeJailbreakDetection.isJailbroken())
        // Calling again installs nothing twice.
        let count = mulg_identity_install_jailbreak_bypass()
        #expect(count == mulg_identity_install_jailbreak_bypass())
    }

    @Test("A check whose return type no longer fits its answer is left alone")
    func mismatchedSignatureIsSkipped() {
        _ = mulg_identity_install_jailbreak_bypass()
        #expect(FakeChangedDeviceInfo().getDeviceType() == "Tablet")
    }

    @Test("Only Endfield gets the alert fix")
    func endfieldOnly() {
        #expect("com.miHoYo.GenshinImpact".withCString { mulg_identity_install_endfield_alert_fix($0) } == 0)
    }
}

@Suite("iPad Pro 13-inch (M5) identity")
struct M5IdentityTests {
    @Test("New games start as the iPad Pro 13-inch (M5), Wi-Fi")
    func defaultDevice() throws {
        #expect(GameSettings().iosDeviceModel == DeviceCatalog.recommendedDefault)
        let profile = try #require(DeviceCatalog.profile(for: "iPad17,3"))
        #expect(profile.name == "iPad Pro (13-inch) (M5)")
        #expect(profile.boardID == "J820AP")
        #expect(profile.maximumRefreshRate == 120)
    }

    @Test("The rest of the identity matches the model")
    func consistentSignals() throws {
        let profile = try #require(DeviceCatalog.profile(for: "iPad17,3"))
        #expect(profile.memoryBytes == 12 * 1_073_741_824)
        #expect(profile.gpuName == "Apple M5 GPU")
        #expect(profile.platform == "t8142")
        #expect(profile.genericName == "iPad")
        #expect(profile.screen == DeviceScreen.iPadPro13)
        #expect(profile.screen.pixelWidth == 2752 && profile.screen.pixelHeight == 2064)
        #expect(profile.screen.pointWidth == 1376 && profile.screen.pointHeight == 1032)
    }

    @Test("Model, board ID, SoC, CPU, memory and screen agree for every device")
    func profilesAgree() throws {
        for profile in DeviceCatalog.all where profile.id != "iPad6,7" {
            #expect(profile.inconsistencies.isEmpty, "\(profile.id): \(profile.inconsistencies)")
        }
        // The A9X's CPU topology is not known yet (asymmetric perflevels do not fit a 2-core chip).
        #expect(try #require(DeviceCatalog.profile(for: "iPad6,7")).inconsistencies.count == 1)
        let wrong = DeviceProfile(id: "iPad17,3", family: .iPad, name: "", chip: "M5", memoryLabel: "12GB",
                                  boardID: "J717AP", boardIDVerified: false, platform: "t8140", maximumRefreshRate: 120)
        #expect(wrong.inconsistencies == ["iPad17,1 has the same M5 chip but platform t8142"])
    }

    @Test("Each identity switch that is off is named, so a half-Mac identity is visible")
    func macAnswers() {
        var settings = IdentitySettings()
        #expect(settings.macAnswers == ["identity.matchDeviceCPU", "identity.matchMobileInterface"])  // deliberate defaults
        settings.presentAsIPad = false
        settings.matchDeviceCPU = false
        #expect(settings.macAnswers == ["identity.presentAsIPad", "identity.matchDeviceCPU", "identity.matchMobileInterface"])
    }

    @Test("Every catalog device has its own screen")
    func everyDeviceHasAScreen() {
        for profile in DeviceCatalog.all {
            #expect(DeviceScreen.byDevice[profile.id] != nil, "\(profile.id) has no screen")
        }
    }

    @Test("Memory is capped at the device's, never raised")
    func memoryCap() {
        let twelve: UInt64 = 12 * 1_073_741_824
        mulg_identity_configure_memory_limit(twelve)
        #expect(mulg_identity_limited_memory(36 * 1_073_741_824) == twelve)
        #expect(mulg_identity_limited_memory(8 * 1_073_741_824) == 8 * 1_073_741_824)
        mulg_identity_configure_memory_limit(0)
        #expect(mulg_identity_limited_memory(36 * 1_073_741_824) == 36 * 1_073_741_824)
    }

    @Test("Free memory follows the kernel's memory level and the device cap, whichever is lower")
    func availableMemory() {
        let gib: UInt64 = 1_073_741_824
        // 16 GB Mac at 72 %: 11.5 GB available, but a 12 GB iPad with a 3 GB footprint leaves 9 GB.
        #expect(mulg_identity_available_memory(12 * gib, 3 * gib, 16 * gib, 72) == 9 * gib)
        // Under pressure the kernel's level decides.
        #expect(mulg_identity_available_memory(12 * gib, 3 * gib, 16 * gib, 20) == 16 * gib / 100 * 20)
        // A footprint above the cap leaves nothing; levels outside 0–100 are clamped.
        #expect(mulg_identity_available_memory(4 * gib, 5 * gib, 16 * gib, 72) == 0)
        #expect(mulg_identity_available_memory(12 * gib, 0, 16 * gib, 140) == 12 * gib)
        #expect(mulg_identity_available_memory(12 * gib, 0, 16 * gib, -5) == 0)
    }

    @Test("Identity settings default to a consistent iPad, GPU name included")
    func settingsDefaults() {
        let settings = IdentitySettings()
        #expect(settings.limitMemoryToDevice)
        #expect(settings.genericDeviceName)
        #expect(settings.presentAsIPad)
        #expect(settings.reportDeviceGPUName)
        // CPU counts pass through by default so engines size worker pools for every Mac core.
        #expect(!settings.matchDeviceCPU)
        #expect(!settings.matchMobileInterface)
    }
}

@Suite("What the hooks answer")
struct HookAnswerTests {
    @Test("sysctl names and MobileGestalt questions all name the iPad Pro 13-inch (M5)")
    func answers() throws {
        func sysctl(_ name: String) -> String? {
            mulg_identity_sysctl_value(name).map { String(cString: $0) }
        }
        func gestalt(_ question: String) -> String? {
            mulg_identity_gestalt_value(question as CFString).map { String(cString: $0) }
        }
        defer {
            mulg_identity_configure(nil, nil)
            mulg_identity_configure_platform(nil, nil)
            mulg_identity_configure_host_name(nil)
            mulg_identity_configure_hardware_platform(nil)
            mulg_identity_configure_screen(0, 0, 0)
            mulg_identity_configure_cpu(0, 0, 0, 0)
        }
        #expect(IdentityModule.start(settings: GameSettings()) == .active(IdentityConfiguration(machine: "iPad17,3", boardID: "J820AP")))
        mulg_identity_configure_platform("iPad", DeviceCatalog.cpuBrandString)
        mulg_identity_configure_host_name("iPad")
        mulg_identity_configure_hardware_platform("t8142")

        #expect(sysctl("hw.machine") == "iPad17,3" && sysctl("hw.product") == "iPad17,3")
        #expect(sysctl("hw.model") == "J820AP" && sysctl("hw.target") == "J820AP")
        #expect(sysctl("hw.targettype") == "J820")
        #expect(sysctl("machdep.cpu.brand_string") == "Apple processor")
        #expect(sysctl("kern.hostname") == "iPad")
        #expect(sysctl("hw.ncpu") == nil)  // a number, answered below

        #expect(gestalt("ProductType") == "iPad17,3" && gestalt("h9jDsbgj7xIVeIQ8S3/X3Q") == "iPad17,3")
        #expect(gestalt("HWModelStr") == "J820AP")
        #expect(gestalt("DeviceClass") == "iPad" && gestalt("DeviceName") == "iPad")
        #expect(gestalt("HardwarePlatform") == "t8142")
        #expect(gestalt("SerialNumber") == nil)
        #expect(gestalt("UserAssignedDeviceName") == "iPad")

        // Numbers: ChipID from the platform, the iPad class, the panel in portrait.
        // [kind, value]: kind 1 is an integer, 2 a floating-point number, 0 the real answer.
        func number(_ question: String) -> [Double] {
            var value = 0.0
            let kind = mulg_identity_gestalt_number(question as CFString, &value)
            return [Double(kind), value]
        }
        mulg_identity_configure_screen(2064, 2752, 2)
        #expect(number("ChipID") == [1, 0x8142])
        #expect(number("DeviceClassNumber") == [1, 3])
        #expect(number("main-screen-width") == [1, 2064] && number("main-screen-height") == [1, 2752])
        #expect(number("main-screen-scale") == [2, 2])
        #expect(number("hw.ncpu")[0] == 0)
        mulg_identity_configure_screen(0, 0, 0)
        #expect(number("main-screen-width")[0] == 0)

        // IOKit's device-tree root: NUL-separated strings, as on the device.
        func deviceTree(_ key: String) -> [String] {
            var bytes = [CChar](repeating: 0, count: 128)
            let length = mulg_identity_platform_expert_value(key as CFString, &bytes, bytes.count)
            return bytes.prefix(length).split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        }
        #expect(deviceTree("model") == ["iPad17,3"])
        #expect(deviceTree("compatible") == ["J820AP", "iPad17,3", "AppleARM"])
        #expect(deviceTree("target-type") == ["J820"])
        #expect(deviceTree("platform-name") == ["t8142"])
        #expect(deviceTree("IOPlatformSerialNumber").isEmpty)  // unique IDs stay the Mac's

        // The M5's CPU: 3 + 6 cores, CPU family 0x1d5a87e8. The test calls from its own image, a game caller.
        func cpu(_ name: String) -> UInt32? {
            var value: UInt32 = 0
            return mulg_identity_cpu_number(name, &value) == 1 ? value : nil
        }
        #expect(cpu("hw.ncpu") == nil && mulg_identity_cpu_count_for_caller(#dsohandle) == 0)
        let m5 = try #require(DeviceCatalog.profile(for: "iPad17,3")?.cpu)
        mulg_identity_configure_cpu(m5.performanceCores, m5.efficiencyCores, m5.family, m5.subfamily)
        #expect(cpu("hw.ncpu") == 9 && cpu("hw.logicalcpu_max") == 9 && cpu("machdep.cpu.core_count") == 9)
        #expect(cpu("hw.nperflevels") == 2)
        #expect(cpu("hw.perflevel0.physicalcpu") == 3 && cpu("hw.perflevel1.logicalcpu_max") == 6)
        #expect(cpu("hw.perflevel0.name") == nil && cpu("hw.perflevel2.physicalcpu") == nil)
        #expect(cpu("hw.cpufamily") == 0x1d5a_87e8 && cpu("hw.cpusubfamily") == 2)
        #expect(cpu("hw.memsize") == nil)
        // This native macOS test image is outside the converted game.
        #expect(mulg_identity_cpu_count_for_caller(#dsohandle) == 0)
        mulg_identity_configure_cpu(0, 0, 0, 0)
        #expect(cpu("hw.cpufamily") == nil)

        // Without "generic device name" the Mac's host name passes through.
        mulg_identity_configure_host_name(nil)
        #expect(sysctl("kern.hostname") == nil)

        // Without "present as iPad" the Mac's class and CPU name pass through; the model stays.
        mulg_identity_configure_platform(nil, nil)
        mulg_identity_configure_hardware_platform(nil)
        #expect(gestalt("HardwarePlatform") == nil && sysctl("kern.version") == nil)
        #expect(gestalt("DeviceClass") == nil && sysctl("machdep.cpu.brand_string") == nil)
        #expect(gestalt("ProductType") == "iPad17,3")

        // Module off: everything is the real value.
        mulg_identity_configure(nil, nil)
        #expect(sysctl("hw.machine") == nil && gestalt("ProductType") == nil)
    }
}

@Suite("Kernel version")
struct KernelVersionTests {
    @Test("The Mac's SoC at the end of the kernel version becomes the iPad's")
    func swapsSoC() throws {
        let mac = "Darwin Kernel Version 26.0.0: Mon Sep  7 21:00:00 PDT 2026; root:xnu-12377.1.9~3/RELEASE_ARM64_T6041"
        let swapped = try #require(mulg_identity_kernel_version(mac, "t8142"))
        defer { free(swapped) }
        #expect(String(cString: swapped)
            == "Darwin Kernel Version 26.0.0: Mon Sep  7 21:00:00 PDT 2026; root:xnu-12377.1.9~3/RELEASE_ARM64_T8142")
        #expect(mulg_identity_kernel_version("Darwin Kernel Version 26.0.0; root:xnu/DEVELOPMENT_X86_64", "t8142") == nil)
    }
}
