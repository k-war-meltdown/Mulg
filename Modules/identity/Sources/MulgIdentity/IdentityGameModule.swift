import Foundation
import MulgContracts
import MulgEngine
import MulgIdentityHooks

/// The identity module inside the game: what device the game thinks it runs on (PLAN.md §3).
/// Starts right after the engine, before the game can read device information.
@MainActor
public final class IdentityGameModule: GameModule {
    public let id = ModuleID.identity

    public private(set) var result: IdentityModule.StartResult?
    private var volumeHooks: Int32 = 0
    /// Whether third-party jailbreak checks are answered for this game (`bypass` setting).
    public private(set) var jailbreakBypass = false
    private var bypassPolicy: EnvironmentBypassPolicy?
    private var launchIdentitySettings: IdentitySettings?
    private var lastBypassReport: EnvironmentBypassReport?
    private var mobileUIHooks: Int32 = 0
    private var platformHooks: Int32 = 0
    private var deviceNameHooks: Int32 = 0
    private var hostNameHooks: Int32 = 0
    private var deviceStringHooks: Int32 = 0
    private var cpuCountHooks: Int32 = 0
    private var memoryHooks: Int32 = 0
    private var gpuNameHooks: Int32 = 0

    public init() {}

    public func prepare(_ context: ModuleContext) throws {
        let launchSettings = context.settings
        let policy = EnvironmentBypassPolicy(settings: launchSettings,
            legacyEnvironmentRequested: mulg_identity_jailbreak_bypass_requested() != 0)
        bypassPolicy = policy
        launchIdentitySettings = launchSettings.mulg.identity.effective
        configureLaunchIdentity(context, settings: launchSettings)

        // Battery and volume are part of what the device reports, so they follow the module.
        if mulg_identity_install_battery_hooks() == 3 {
            for property in ["isBatteryMonitoringEnabled", "batteryState", "batteryLevel"] {
                try? context.hooks.claim("UIDevice.\(property)", owner: id, kind: .swizzle)
            }
        }
        volumeHooks = mulg_identity_install_volume_hooks()

        claimCompatAnswers(mulg_identity_install_compat_answers(), context: context)

        // Upstream: per game, off by default (§15 rule 5).
        jailbreakBypass = policy.answersKnownSDKChecks
        if jailbreakBypass {
            claimJailbreakBypass(mulg_identity_install_jailbreak_bypass(), context: context)
        } else {
            reportBypass(installedChecks: 0, context: context)
        }
        if context.bundleIdentifier.withCString({ mulg_identity_install_endfield_alert_fix($0) }) == 1 {
            try? context.hooks.claim("UIViewController.presentViewController:animated:completion: (Endfield alerts)",
                                     owner: id, kind: .swizzle)
        }

        reportBypass(installedChecks: lastBypassReport?.installedSDKChecks ?? 0, context: context)
    }

    private func configureLaunchIdentity(_ context: ModuleContext, settings: GameSettings) {
        // Getters stay native until both the C profile and Objective-C replacements
        // are ready. Do not run this transaction again while the game is playing.
        mulg_identity_begin_profile_configuration()
        defer { mulg_identity_finish_profile_configuration() }
        let result = IdentityModule.start(settings: settings)
        self.result = result

        switch result {
        case .active(let configuration):
            for function in ["uname", "sysctl", "sysctlbyname"] {
                try? context.hooks.claim(function, owner: id, kind: .interpose)
            }
            // Game callers only; Apple's frameworks keep the Mac's answers.
            try? context.hooks.claim("MGCopyAnswer", owner: id, kind: .interpose, privateAPI: true)
            if mulg_identity_iokit_hooked() == 1 {
                for function in ["IORegistryEntryCreateCFProperty", "IORegistryEntrySearchCFProperty",
                                 "IORegistryEntryCreateCFProperties"] {
                    try? context.hooks.claim("\(function) (IOPlatformExpertDevice)", owner: id, kind: .interpose)
                }
            }
            if mulg_identity_has_configured_profile(), let profile = DeviceCatalog.profile(for: configuration.machine,
                configuration: settings.mulg.identity.deviceConfiguration) {
                matchRestOfIdentity(profile, identity: settings.mulg.identity.effective, context: context)
                context.logger(for: id).info(
                    "Reporting \(configuration.machine, privacy: .public) / \(configuration.boardID, privacy: .public)")
            } else {
                context.notices.show(Notice("Device identity unavailable",
                    lines: ["The profile could not be configured. Native device answers are kept for this launch."],
                    style: .warning))
                context.logger(for: id).error("Could not allocate the selected device identity")
            }
        case .unknownDevice(let identifier):
            context.notices.show(Notice(
                "Unknown device \(identifier)",
                lines: ["Pick a device in the game's settings; the real Mac model is reported for now."],
                style: .warning))
        case .switchedOff:
            break
        }
        installPlatformHooks(context)
    }
}

extension IdentityGameModule {
    public func imagesChanged(_ context: ModuleContext) {
        // Each C installer remembers resolved targets; only missing classes are attempted.
        volumeHooks = mulg_identity_install_volume_hooks()
        claimCompatAnswers(mulg_identity_install_compat_answers(), context: context)
        if jailbreakBypass { claimJailbreakBypass(mulg_identity_install_jailbreak_bypass(), context: context) }
        refreshIdentityHooks(context)
    }

    /// MediaPlayer is often loaded only when the game first plays media, so the volume hooks
    /// are tried again once the scene is active.
    public func activate(_ context: ModuleContext) {
        volumeHooks = mulg_identity_install_volume_hooks()
        claimCompatAnswers(mulg_identity_install_compat_answers(), context: context)
        if jailbreakBypass {
            claimJailbreakBypass(mulg_identity_install_jailbreak_bypass(), context: context)
        }
        if volumeHooks > 0 {
            try? context.hooks.claim("AVAudioSession.outputVolume and media volume controls", owner: id, kind: .swizzle,
                                     privateAPI: true)
        }
        refreshIdentityHooks(context)
    }
}

extension IdentityGameModule {
    func claimCompatAnswers(_ count: Int32, context: ModuleContext) {
        guard count > 0 else { return }
        if NSClassFromString("ATTrackingManager") != nil {
            try? context.hooks.claim("ATTrackingManager (tracking answered as denied)", owner: id, kind: .swizzle)
        }
        if NSClassFromString("KRDeclaredAgeRangeService") != nil {
            try? context.hooks.claim("KRDeclaredAgeRangeService.isAgeRangeRequestAvailable", owner: id, kind: .swizzle,
                                     privateAPI: true)
        }
    }
}

extension IdentityGameModule {
    func claimJailbreakBypass(_ count: Int32, context: ModuleContext) {
        let changed = lastBypassReport?.installedSDKChecks != count
        reportBypass(installedChecks: count, context: context)
        guard changed else { return }
        context.logger(for: id).info(
            "Jailbreak bypass: \(count) of \(mulg_identity_jailbreak_bypass_entry_count()) known SDK checks answered")
        if count > 0 {
            try? context.hooks.claim("Third-party jailbreak checks (upstream's list)", owner: id, kind: .swizzle)
        }
    }

    private func reportBypass(installedChecks: Int32, context: ModuleContext) {
        guard let policy = bypassPolicy else { return }
        let report = EnvironmentBypassReport(processIdentifier: ProcessInfo.processInfo.processIdentifier,
            launchStartedAt: policy.launchStartedAt,
            bundleIdentifier: context.bundleIdentifier, deviceIdentifier: policy.deviceIdentifier,
            enabled: policy.enabled,
            deviceRecognized: DeviceCatalog.profile(for: policy.deviceIdentifier) != nil,
            knownSDKChecksRequested: policy.answersKnownSDKChecks,
            installedSDKChecks: installedChecks,
            availableSDKChecks: mulg_identity_jailbreak_bypass_entry_count(),
            mobileUIHooksInstalled: mobileUIHooks,
            identityAudit: identityAudit(), launchSessionID: context.launchSessionID)
        guard report != lastBypassReport else { return }
        lastBypassReport = report
        ReportWriter.shared.write(report, to: context.paths.diagnosticsDirectory(for: context.bundleIdentifier)
            .appendingPathComponent("environment-bypass.json"))
    }
}

extension IdentityGameModule {
    /// Makes every other device signal agree with the spoofed model (PLAN.md §3.7), so the game
    /// sees one consistent iPad Pro 13-inch (M5): its memory range, its generic name, "iPad"
    /// and "iPadOS" (UIDevice and MobileGestalt), an iPad CPU brand string, its SoC ("t8142" in
    /// MobileGestalt, IOKit and the kernel version; ChipID 0x8142), its panel in MobileGestalt, the
    /// iPad's device-tree names in IOKit, not an iOS app on a Mac, its GPU name, and its CPU (9 cores
    /// as 3 + 6, or 10 as 4 + 6 for the high-capacity variant, CPU family 0x1d5a87e8).
    /// The screen is the display module's "match device" resolution
    /// (2752 × 2064 at 2×). Names, ranges and counts only: the Mac's GPU features are never faked.
    private func matchRestOfIdentity(_ profile: DeviceProfile, identity: IdentitySettings, context: ModuleContext) {
        if identity.matchMobileInterface { installMobileIdentity(profile, context: context) }
        let logger = context.logger(for: id)
        for problem in profile.inconsistencies {
            logger.error("Identity mismatch: \(problem, privacy: .public)")
        }
        if !identity.macAnswers.isEmpty {
            logger.notice("Mac answers pass through (\(identity.macAnswers.joined(separator: ", "), privacy: .public)): the game sees parts of two devices")
        }

        if identity.limitMemoryToDevice, profile.memoryBytes > 0 {
            mulg_identity_configure_memory_limit(profile.memoryBytes)
            try? context.hooks.claim("hw.memsize (capped at the device's memory)", owner: id, kind: .interpose)
            memoryHooks = mulg_identity_install_memory_hook()
            if memoryHooks == 1 {
                try? context.hooks.claim("NSProcessInfo.physicalMemory", owner: id, kind: .swizzle)
            }
        } else {
            mulg_identity_configure_memory_limit(0)
        }
        if identity.genericDeviceName {
            deviceNameHooks = mulg_identity_install_device_name_hook(profile.genericName)
            if deviceNameHooks == 1 { try? context.hooks.claim("UIDevice.name", owner: id, kind: .swizzle) }
        }
        // The Mac's host name names the player too; game callers only.
        mulg_identity_configure_host_name(identity.genericDeviceName ? profile.genericName : nil)
        if identity.genericDeviceName {
            try? context.hooks.claim("gethostname", owner: id, kind: .interpose)
            hostNameHooks = mulg_identity_install_host_name_hook()
            if hostNameHooks == 1 {
                try? context.hooks.claim("NSProcessInfo.hostName", owner: id, kind: .swizzle)
            }
        }

        mulg_identity_set_reports_mac(!identity.presentAsIPad)
        if identity.presentAsIPad {
            mulg_identity_configure_platform(profile.genericName, DeviceCatalog.cpuBrandString)
            mulg_identity_configure_hardware_platform(profile.platform)
            // MobileGestalt reports the panel in portrait: short side first.
            mulg_identity_configure_screen(Int32(profile.screen.pixelHeight), Int32(profile.screen.pixelWidth),
                                           profile.screen.scale)
            let systemName = profile.family == .iPad ? "iPadOS" : "iOS"
            deviceStringHooks = mulg_identity_install_device_strings(profile.genericName, systemName)
            for property in ["model", "localizedModel", "systemName"] {
                try? context.hooks.claim("UIDevice.\(property)", owner: id, kind: .swizzle)
            }
        } else {
            mulg_identity_configure_platform(nil, nil)
            mulg_identity_configure_hardware_platform(nil)
            mulg_identity_configure_screen(0, 0, 0)
        }

        if identity.matchDeviceCPU, let cpu = profile.cpu {
            // The game sees exactly the device's cores. It still runs on every core of the Mac:
            // macOS schedules its threads everywhere, and Metal and GCD see the real cores.
            mulg_identity_configure_cpu(cpu.performanceCores, cpu.efficiencyCores, cpu.family, cpu.subfamily)
            try? context.hooks.claim("hw.ncpu, hw.perflevel*, hw.cpufamily (the device's CPU; game callers only)",
                                     owner: id, kind: .interpose)
            try? context.hooks.claim("sysconf (processor counts; game callers only)", owner: id, kind: .interpose)
            cpuCountHooks = mulg_identity_install_cpu_count_hooks()
            for property in ["processorCount", "activeProcessorCount"] {
                try? context.hooks.claim("NSProcessInfo.\(property)", owner: id, kind: .swizzle)
            }
        } else {
            mulg_identity_configure_cpu(0, 0, 0, 0)
        }

        if identity.reportDeviceGPUName {
            gpuNameHooks = mulg_identity_install_gpu_name_hook(profile.gpuName)
            if gpuNameHooks == 1 {
                // The C registry records the actual driver's class, not the MTLDevice protocol.
                context.hooks.refreshInstallationReports()
                logger.notice("Reporting GPU name \(profile.gpuName, privacy: .public) (unverified on a real device)")
            }
        }
        logger.info("Identity: \(profile.name, privacy: .public), \(profile.memoryLabel, privacy: .public), screen \(profile.screen.pixelWidth)×\(profile.screen.pixelHeight)")
    }

    private func installMobileIdentity(_ profile: DeviceProfile, context: ModuleContext) {
        mobileUIHooks = mulg_identity_install_mobile_ui_hooks(profile.interfaceIdiom)
        for cls in ["UIDevice", "UITraitCollection"] {
            try? context.hooks.claim("\(cls).userInterfaceIdiom", owner: id, kind: .swizzle)
        }
    }

    private func installPlatformHooks(_ context: ModuleContext) {
        platformHooks = mulg_identity_install_platform_hooks()
        for property in ["isMacCatalystApp", "isiOSAppOnMac"] {
            try? context.hooks.claim("NSProcessInfo.\(property)", owner: id, kind: .swizzle)
        }
    }

    private func refreshIdentityHooks(_ context: ModuleContext) {
        if case .active(let configuration)? = result,
           let identity = launchIdentitySettings,
           let profile = DeviceCatalog.profile(for: configuration.machine, configuration: identity.deviceConfiguration) {
            retryIdentityHooks(profile, identity: identity, context: context)
        }
        reportBypass(installedChecks: lastBypassReport?.installedSDKChecks ?? 0, context: context)
    }

    private func retryIdentityHooks(_ profile: DeviceProfile, identity: IdentitySettings, context: ModuleContext) {
        guard IdentityModule.isActive else { return }
        // Profile and effective preferences belong to this launch. A settings edit while
        // the game runs cannot change half the identity when another framework loads.
        // Ordinary mode needs the same retries, limited to the options it requested.
        if identity.matchMobileInterface, mobileUIHooks < 2 { installMobileIdentity(profile, context: context) }
        if identity.genericDeviceName, deviceNameHooks < 1 {
            deviceNameHooks = mulg_identity_install_device_name_hook(profile.genericName)
            if deviceNameHooks == 1 { try? context.hooks.claim("UIDevice.name", owner: id, kind: .swizzle) }
        }
        if identity.genericDeviceName, hostNameHooks < 1 {
            hostNameHooks = mulg_identity_install_host_name_hook()
            if hostNameHooks == 1 { try? context.hooks.claim("NSProcessInfo.hostName", owner: id, kind: .swizzle) }
        }
        if identity.presentAsIPad, deviceStringHooks < 3 {
            deviceStringHooks = mulg_identity_install_device_strings(profile.genericName,
                profile.family == .iPad ? "iPadOS" : "iOS")
            for property in ["model", "localizedModel", "systemName"] {
                try? context.hooks.claim("UIDevice.\(property)", owner: id, kind: .swizzle)
            }
        }
        if platformHooks < 2 { installPlatformHooks(context) }
        if identity.limitMemoryToDevice, profile.memoryBytes > 0, memoryHooks < 1 {
            memoryHooks = mulg_identity_install_memory_hook()
            if memoryHooks == 1 { try? context.hooks.claim("NSProcessInfo.physicalMemory", owner: id, kind: .swizzle) }
        }
        if identity.matchDeviceCPU, cpuCountHooks < 2, profile.cpu != nil {
            cpuCountHooks = mulg_identity_install_cpu_count_hooks()
            for property in ["processorCount", "activeProcessorCount"] {
                try? context.hooks.claim("NSProcessInfo.\(property)", owner: id, kind: .swizzle)
            }
        }
        if identity.reportDeviceGPUName, gpuNameHooks < 1 {
            gpuNameHooks = mulg_identity_install_gpu_name_hook(profile.gpuName)
        }
        context.hooks.refreshInstallationReports()
    }

    private func identityAudit() -> DeviceIdentityAudit? {
        guard let policy = bypassPolicy, policy.enabled,
              let identity = launchIdentitySettings,
              let profile = DeviceCatalog.profile(for: policy.deviceIdentifier,
                  configuration: identity.deviceConfiguration) else { return nil }
        let memory = mulg_identity_limited_memory(ProcessInfo.processInfo.physicalMemory)
        var warnings = profile.inconsistencies
        if identity.deviceConfiguration != profile.configuration {
            warnings.append("The selected device has no high-capacity CPU/RAM variant in Mulg's catalog. Its standard profile is used.")
        }
        if memory < profile.memoryBytes { warnings.append("Available Mac RAM is below the selected device's RAM. Memory is never overstated.") }
        if !IdentityModule.isActive { warnings.append("Machine and board answers were not configured.") }
        return DeviceIdentityAudit(profileName: profile.name, boardIdentifier: profile.boardID,
            hardwarePlatform: profile.platform, cpuCores: IdentityModule.isActive ? profile.cpu?.totalCores : nil,
            memoryLimitBytes: IdentityModule.isActive ? profile.memoryBytes : 0, reportedMemoryBytes: memory,
            configured: IdentityModule.isActive, gameOnlyAnswers: mulg_identity_game_only_answers(),
            boardVerified: profile.boardIDVerified,
            hooks: [IdentityHookCoverage(id: "platform", title: "Mac platform flags", installed: platformHooks, expected: 2),
                    .init(id: "name", title: "Device name", installed: deviceNameHooks, expected: 1),
                    .init(id: "hostname", title: "Host name", installed: hostNameHooks, expected: 1),
                    .init(id: "strings", title: "Device and system names", installed: deviceStringHooks, expected: 3),
                    .init(id: "idiom", title: "Mobile interface", installed: mobileUIHooks, expected: 2),
                    .init(id: "cpu", title: "CPU counts", installed: cpuCountHooks, expected: 2),
                    .init(id: "memory", title: "RAM limit", installed: memoryHooks, expected: 1),
                    .init(id: "gpu", title: "GPU name", installed: gpuNameHooks, expected: 1)], warnings: warnings,
            signals: configuredIdentitySignals(profile), deviceConfiguration: profile.configuration)
    }

    private func configuredIdentitySignals(_ profile: DeviceProfile) -> [DeviceIdentitySignal] {
        // Read the published C table instead of repeating selected settings as evidence.
        // These helpers do not invoke or impersonate a game's integrity check.
        let stringFields: [(id: String, title: String, key: String, expected: String)] = [
            ("machine", "Machine", "hw.machine", profile.id),
            ("board", "Board", "hw.model", profile.boardID),
            ("target", "Target", "hw.targettype", String(profile.boardID.dropLast(2))),
            ("hostname", "Host name", "kern.hostname", profile.genericName),
            ("brand", "CPU brand", "machdep.cpu.brand_string", DeviceCatalog.cpuBrandString)]
        var signals = stringFields.map { field in
            DeviceIdentitySignal(id: field.id, title: field.title, expected: field.expected,
                configured: field.key.withCString { mulg_identity_sysctl_value($0).map { String(cString: $0) } })
        }
        for (id, title, key, expected) in [("class", "Device class", "DeviceClass", profile.genericName),
                                         ("platform", "Chip platform", "HardwarePlatform", profile.platform)] {
            signals.append(.init(id: id, title: title, expected: expected,
                configured: mulg_identity_gestalt_value(key as CFString).map { String(cString: $0) }))
        }
        var numberFields: [(String, String, String, Double, Int32)] = [
            ("panelWidth", "Panel width", "main-screen-width", Double(profile.screen.pixelHeight), Int32(1)),
            ("panelHeight", "Panel height", "main-screen-height", Double(profile.screen.pixelWidth), Int32(1)),
            ("panelScale", "Panel scale", "main-screen-scale", profile.screen.scale, Int32(2)),
            ("classNumber", "Device class number", "DeviceClassNumber", profile.family == .iPad ? 3 : 1, Int32(1))]
        if let chipID = UInt32(profile.platform.dropFirst(), radix: 16) {
            numberFields.append(("chipID", "Chip ID", "ChipID", Double(chipID), 1))
        }
        for (id, title, key, expected, kind) in numberFields {
            var value = 0.0
            let actualKind = mulg_identity_gestalt_number(key as CFString, &value)
            signals.append(.init(id: id, title: title, expected: String(expected),
                configured: actualKind == kind ? String(value) : nil))
        }
        if let cpu = profile.cpu {
            for (id, title, key, expected) in [
                ("cores", "Total cores", "hw.ncpu", cpu.totalCores),
                ("performanceCores", "Performance cores", "hw.perflevel0.physicalcpu", cpu.performanceCores),
                ("efficiencyCores", "Efficiency cores", "hw.perflevel1.physicalcpu", cpu.efficiencyCores),
                ("cpuFamily", "CPU family", "hw.cpufamily", cpu.family),
                ("cpuSubfamily", "CPU subfamily", "hw.cpusubfamily", cpu.subfamily)] {
                var value: UInt32 = 0
                let configured = key.withCString { mulg_identity_cpu_number($0, &value) == 1 }
                signals.append(.init(id: id, title: title, expected: String(expected),
                    configured: configured ? String(value) : nil))
            }
        }
        let limit = mulg_identity_limited_memory(UInt64.max)
        signals.append(.init(id: "memoryCap", title: "RAM cap", expected: String(profile.memoryBytes),
            configured: limit == UInt64.max ? nil : String(limit)))
        for (id, title, property, expected) in [
            ("deviceName", "Device name", "UIDevice.name", profile.genericName),
            ("deviceModel", "Device model", "UIDevice.model", profile.genericName),
            ("localizedModel", "Localized model", "UIDevice.localizedModel", profile.genericName),
            ("systemName", "System name", "UIDevice.systemName", profile.family == .iPad ? "iPadOS" : "iOS")] {
            var buffer = [CChar](repeating: 0, count: 256)
            let copied = property.withCString { name in
                buffer.withUnsafeMutableBufferPointer { output in
                    mulg_identity_copy_device_string(name, output.baseAddress, output.count) == 1
                }
            }
            signals.append(.init(id: id, title: title, expected: expected,
                configured: copied ? Self.string(fromCBuffer: buffer) : nil))
        }
        var gpuBuffer = [CChar](repeating: 0, count: 256)
        let gpuCopied = gpuBuffer.withUnsafeMutableBufferPointer {
            mulg_identity_copy_gpu_name($0.baseAddress, $0.count) == 1
        }
        signals.append(.init(id: "gpuName", title: "GPU name", expected: profile.gpuName,
            configured: gpuCopied ? Self.string(fromCBuffer: gpuBuffer) : nil))
        let platformFields: [(String, String, String, Int32)] = [
            ("catalyst", "Catalyst flag", "NSProcessInfo.isMacCatalystApp", 0),
            ("iosOnMac", "iOS-on-Mac flag", "NSProcessInfo.isiOSAppOnMac", 0),
            ("deviceIdiom", "Device interface", "UIDevice.userInterfaceIdiom", profile.interfaceIdiom),
            ("traitIdiom", "Trait interface", "UITraitCollection.userInterfaceIdiom", profile.interfaceIdiom)]
        for (id, title, property, expected) in platformFields {
            var value: Int32 = 0
            let available = property.withCString { mulg_identity_platform_number($0, &value) == 1 }
            signals.append(.init(id: id, title: title, expected: String(expected),
                configured: available ? String(value) : nil))
        }
        return signals
    }
}

extension IdentityGameModule {
    /// The text before the first NUL; the whole buffer when a C function filled it without one.
    nonisolated static func string(fromCBuffer buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
