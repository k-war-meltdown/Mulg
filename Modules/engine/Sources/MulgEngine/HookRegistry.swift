import Foundation
import MulgContracts
import MulgEngineHooks

/// Who hooked what (PLAN.md §1.5 rule 4, §12 #17).
///
/// The hooks themselves are installed by each module's Objective-C code. Every installed
/// hook is claimed here with its owner, so:
/// - two modules can never hook the same method without it being noticed;
/// - diagnostics can list every hook and every private Apple class in use (the
///   private-API register), to re-check after each macOS update.
@MainActor
public final class HookRegistry {
    public enum Kind: String, Sendable {
        /// Objective-C method replacement.
        case swizzle
        /// C function replacement through dyld interposing.
        case interpose
    }

    public struct Entry: Sendable, Hashable {
        /// "Class.selector" for swizzles, the function name for interposes.
        public let target: String
        public let owner: ModuleID
        public let kind: Kind
        /// Whether the target is a private Apple class or function.
        public let isPrivateAPI: Bool
    }

    public enum ClaimError: Error, Equatable, CustomStringConvertible {
        case alreadyClaimed(target: String, owner: ModuleID)
        case notInstalled(String)

        public var description: String {
            switch self {
            case let .alreadyClaimed(target, owner): "\(target) is already hooked by \(owner.rawValue)"
            case .notInstalled(let target): "\(target) was not installed by the hook registry"
            }
        }
    }

    public private(set) var entries: [String: Entry] = [:]
    /// Hooks a module tried to install but could not (class or method missing on this macOS).
    public private(set) var missing: [Entry] = []
    public private(set) var conflicts: [Entry] = []
    /// Hooks on one engine's classes (by name) that this game does not have: nothing to hook,
    /// so the module is not degraded by them.
    public private(set) var notApplicable: [Entry] = []

    private static let publicClasses: Set<String> = ["UIApplication", "UIScreen", "CADisplayLink", "MTKView",
        "CMMotionManager", "GCController", "GCMouse", "NSProcessInfo", "NSString", "UIDevice", "AVAudioSession",
        "ATTrackingManager", "UIViewController", "CAMetalLayer"]

    public init() {}

    public func claim(_ target: String, owner: ModuleID, kind: Kind, privateAPI: Bool = false) throws(ClaimError) {
        if kind == .swizzle {
            refreshInstallationReports()
            // Report targets carry "-" (instance) or "+" (class); claims may leave it out.
            let actual = [target, "-" + target, "+" + target].lazy.compactMap { self.entries[$0] }
                .first { $0.owner == owner }
            guard let actual else { throw .notInstalled(target) }
            entries[actual.target] = Entry(target: actual.target, owner: owner, kind: kind, isPrivateAPI: privateAPI)
            return
        }
        if let existing = entries[target], existing.owner != owner {
            throw .alreadyClaimed(target: target, owner: existing.owner)
        }
        entries[target] = Entry(target: target, owner: owner, kind: kind, isPrivateAPI: privateAPI)
    }

    /// Records a hook that could not be installed, so diagnostics can show it.
    public func recordMissing(_ target: String, owner: ModuleID, kind: Kind, privateAPI: Bool = false) {
        let entry = Entry(target: target, owner: owner, kind: kind, isPrivateAPI: privateAPI)
        if !missing.contains(entry) { missing.append(entry) }
    }

    /// The C registry enforces ownership before the IMP changes, including hooks installed later
    /// on render threads. Swift exposes its actual results alongside interposed C functions.
    /// The C registry's report generation last read; nil before the first read.
    private var readGeneration: UInt64?

    public func refreshInstallationReports() {
        // Modules claim hooks one by one; only a changed snapshot is converted and read again.
        let generation = mulg_hook_installation_generation()
        guard generation != readGeneration else { return }
        readGeneration = generation
        for report in mulg_hook_installation_reports() {
            guard let target = report["target"] as? String,
                  let name = report["owner"] as? String, let owner = ModuleID(rawValue: name),
                  let result = report["result"] as? NSNumber else { continue }
            let parts = target.dropFirst().split(separator: ".", maxSplits: 1)
            let knownPublic = parts.first.map { Self.publicClasses.contains(String($0)) } ?? false
            let privateSelector = parts.count > 1 && parts[1].hasPrefix("_")
            let entry = Entry(target: target, owner: owner, kind: .swizzle,
                              isPrivateAPI: entries[target]?.isPrivateAPI ?? (!knownPublic || privateSelector))
            switch result.intValue {
            case 0:
                entries[target] = entry
                missing.removeAll { $0.target == target && $0.owner == owner }
                conflicts.removeAll { $0.target == target && $0.owner == owner }
            case 3:
                if !conflicts.contains(entry) { conflicts.append(entry) }
            case 1 where (report["absent"] as? Bool) == true:
                if !notApplicable.contains(entry) { notApplicable.append(entry) }
            default:
                if !missing.contains(entry) { missing.append(entry) }
            }
        }
    }

    public func hooks(ownedBy owner: ModuleID) -> [Entry] {
        entries.values.filter { $0.owner == owner }.sorted { $0.target < $1.target }
    }

    /// Every private Apple class or function in use, for the private-API register.
    public var privateAPIRegister: [Entry] {
        entries.values.filter(\.isPrivateAPI).sorted { $0.target < $1.target }
    }
}
