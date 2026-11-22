import Foundation
import MulgContracts
import MulgEngineHooks
import os

/// Starts the game-side modules in the fixed order (PLAN.md §1.5 rule 5), honours the
/// per-game on/off switches (rule 7) and safe mode (rule 10), and times each start with
/// signposts so start-up cost stays visible (§16.4 X3).
@MainActor
public final class ModuleHost {
    /// The required start order: identity first, before the game can read device information.
    public static let startOrder: [ModuleID] = [
        .engine, .identity, .display, .graphics, .controls, .mapper, .camera, .diagnostics, .integrations
    ]

    public let context: ModuleContext
    public private(set) var modules: [any GameModule]
    public private(set) var reports: [ModuleID: ModuleReport] = [:]
    private var activated = false
    private var prepared = false
    private let signposter = MulgLog.signposter(.engine)
    private let logger = MulgLog.logger(.engine)

    public init(context: ModuleContext, modules: [any GameModule]) {
        self.context = context
        // Sort into the start order; modules not in the list go last, in the order given.
        let order = Dictionary(uniqueKeysWithValues: Self.startOrder.enumerated().map { ($1, $0) })
        self.modules = modules.enumerated().sorted { lhs, rhs in
            let left = order[lhs.element.id] ?? Self.startOrder.count + lhs.offset
            let right = order[rhs.element.id] ?? Self.startOrder.count + rhs.offset
            return left < right
        }.map(\.element)
    }

    /// Whether a module may start in this launch, and if not, why.
    public func startDecision(for module: any GameModule) -> ModuleState? {
        if !context.settings.mulg.engine.isModuleEnabled(module.id) {
            return .switchedOff
        }
        if context.launch.isSafe && module.isExperimental {
            return .offInSafeMode
        }
        if context.launch.isMinimal && !module.id.isEssential && module.id != .diagnostics {
            return .offInSafeMode
        }
        return nil
    }

    /// Phase 1, before the game's code runs.
    public func prepareAll() {
        guard !prepared else { return }
        prepared = true
        let clock = ContinuousClock()
        for module in modules {
            context.reportLaunchStage?(.preparing, module.id)
            if let prerequisite = module.prerequisites.first(where: { reports[$0]?.state.isRunning != true }) {
                reports[module.id] = ModuleReport(id: module.id, state: .unavailable("\(prerequisite.rawValue) did not prepare"),
                                                   prepareDuration: .zero, activateDuration: .zero)
                continue
            }
            if module.requiresBridge(context.settings) && context.bridge == nil {
                reports[module.id] = ModuleReport(id: module.id, state: .unavailable("Mac bridge did not load"),
                                                   prepareDuration: .zero, activateDuration: .zero)
                continue
            }
            let skipped = startDecision(for: module)
            let interval = signposter.beginInterval("prepare", id: signposter.makeSignpostID(), "\(module.id.rawValue, privacy: .public)")
            var state = ModuleState.prepared
            let duration = clock.measure {
                do {
                    if let skipped {
                        state = try module.prepareCore(context) ? .coreOnly(String(describing: skipped)) : skipped
                    } else {
                        try module.prepare(context)
                    }
                } catch {
                    // Swizzles cannot be rolled back safely after publication. Keep partial
                    // preparation visible and do not activate a module whose prepare threw.
                    state = .failed("\(error); installed hooks remain in place")
                }
            }
            context.hooks.refreshInstallationReports()
            #if DEBUG
            if context.hooks.conflicts.contains(where: { $0.owner == module.id }) {
                state = .failed("Hook ownership conflict; conflicting replacement was rejected")
            }
            #endif
            if state == .prepared && (context.hooks.missing.contains(where: { $0.owner == module.id })
                                      || context.hooks.conflicts.contains(where: { $0.owner == module.id })) {
                state = .degraded("Some hooks are missing or were rejected; available services remain running")
            }
            signposter.endInterval("prepare", interval)
            reports[module.id] = ModuleReport(id: module.id, state: state, prepareDuration: duration, activateDuration: .zero)
            if case .failed(let reason) = state {
                logger.error("\(module.id.rawValue, privacy: .public) failed to start: \(reason, privacy: .public)")
            }
        }
        // Diagnostics and late-image registration are outside a module's preparation.
        context.reportLaunchStage?(.waitingForScene, nil)
        writeStartup()
        mulg_engine_observe_images { [weak self] in
            MainActor.assumeIsolated {
                self?.retryUnresolvedHooks()
            }
        }
    }

    func retryUnresolvedHooks() {
        for module in modules where reports[module.id]?.state.isRunning == true {
            module.imagesChanged(context)
        }
        context.hooks.refreshInstallationReports()
    }

    /// Phase 2, once the first scene is active. Runs only once.
    public func activateAll() {
        guard !activated else { return }
        activated = true
        let clock = ContinuousClock()
        for module in modules where reports[module.id]?.state.isRunning == true {
            context.reportLaunchStage?(.activating, module.id)
            let interval = signposter.beginInterval("activate", id: signposter.makeSignpostID(), "\(module.id.rawValue, privacy: .public)")
            let duration = clock.measure {
                module.activate(context)
            }
            signposter.endInterval("activate", interval)
            if reports[module.id]?.state == .prepared { reports[module.id]?.state = .active }
            reports[module.id]?.activateDuration = duration
        }
        let ordered = modules.compactMap { reports[$0.id] }
        writeStartup()
        context.events.publish(ModulesStarted(reports: ordered))
        context.events.publish(SceneActivated())
        context.reportLaunchStage?(.running, nil)
    }

    /// Modules switched off because of safe mode, for the notice shown to the user.
    public var modulesOffInSafeMode: [ModuleID] {
        reports.values.filter {
            $0.state == .offInSafeMode || $0.state == .coreOnly(String(describing: ModuleState.offInSafeMode))
        }.map(\.id).sorted()
    }

    public func module(_ id: ModuleID) -> (any GameModule)? {
        modules.first { $0.id == id }
    }

    /// Module availability belongs to the engine, even when optional diagnostics is disabled.
    private func writeStartup() {
        context.writeSettingsReport()
        struct Hook: Encodable, Sendable {
            let target: String, owner: String, kind: String
            let privateAPI: Bool, installed: Bool
            var failure: String? = nil
        }
        struct Module: Encodable, Sendable {
            let id: String, state: String
            let prepareMs: Double, activateMs: Double
        }
        struct Startup: Encodable, Sendable {
            let mulgVersion: String
            let runtimeProtocol: Int
            let processIdentifier: Int32
            let launchSessionID: UUID
            let safeMode: Bool
            let modules: [Module]
            let hooks: [Hook]
        }
        func milliseconds(_ duration: Duration) -> Double {
            let parts = duration.components
            return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
        }
        context.hooks.refreshInstallationReports()
        let hooks = context.hooks.entries.values.map {
            Hook(target: $0.target, owner: $0.owner.rawValue, kind: $0.kind.rawValue, privateAPI: $0.isPrivateAPI, installed: true)
        } + context.hooks.missing.map {
            Hook(target: $0.target, owner: $0.owner.rawValue, kind: $0.kind.rawValue, privateAPI: $0.isPrivateAPI, installed: false)
        } + context.hooks.conflicts.map {
            Hook(target: $0.target, owner: $0.owner.rawValue, kind: $0.kind.rawValue,
                 privateAPI: $0.isPrivateAPI, installed: false, failure: "ownership conflict; replacement rejected")
        } + context.hooks.notApplicable.map {
            Hook(target: $0.target, owner: $0.owner.rawValue, kind: $0.kind.rawValue,
                 privateAPI: $0.isPrivateAPI, installed: false, failure: "not used by this game")
        }
        let modules = self.modules.compactMap { reports[$0.id] }.map {
            Module(id: $0.id.rawValue, state: String(describing: $0.state),
                   prepareMs: milliseconds($0.prepareDuration), activateMs: milliseconds($0.activateDuration))
        }
        let report = Startup(mulgVersion: MulgVersion.current, runtimeProtocol: MulgVersion.runtimeProtocol,
                             processIdentifier: ProcessInfo.processInfo.processIdentifier,
                             launchSessionID: context.launchSessionID, safeMode: context.launch.isSafe,
                             modules: modules, hooks: hooks.sorted { $0.target < $1.target })
        ReportWriter.shared.writeSnapshot(report, to: context.paths.diagnosticsDirectory(for: context.bundleIdentifier)
            .appendingPathComponent("startup.json"))
    }
}
