import Foundation

/// One module card, `Modules/<id>/module.yaml` (PLAN.md §1.4).
struct ModuleCard: Decodable {
    struct Ownership: Decodable {
        var paths: [String]?
        var exclude: [String]?
        var settings: [String]?
        var hooks: [String]?
    }

    struct PendingSplit: Decodable {
        var file: String
        var move: String
        var to: String
    }

    struct Events: Decodable {
        var listens: [String]?
        var publishes: [String]?
    }

    var id: String
    var kind: String
    var runsIn: String
    var summary: String
    var status: String
    var defaultState: String
    var dependsOn: [String]?
    var owns: Ownership?
    var pendingSplits: [PendingSplit]?
    var events: Events?

    /// Card path relative to the repository root, filled in after loading.
    var relativePath: String = ""

    enum CodingKeys: String, CodingKey {
        case id, kind, summary, status, owns, events
        case runsIn = "runs_in"
        case defaultState = "default"
        case dependsOn = "depends_on"
        case pendingSplits = "pending_splits"
    }

    var dependencies: [String] { dependsOn ?? [] }
    var ownedPaths: [String] { owns?.paths ?? [] }
    var excludedPaths: [String] { owns?.exclude ?? [] }
    var splits: [PendingSplit] { pendingSplits ?? [] }
}

/// The rules every card is checked against (PLAN.md §1.2 and §1.5).
enum ModuleRules {
    static let kinds: Set<String> = [
        "gui", "engine", "controls", "identity", "display", "graphics",
        "host-service", "contract", "bridge", "diagnostics", "integration"
    ]
    static let runsIn: Set<String> = ["host", "game", "both"]
    static let statuses: Set<String> = ["stable", "experimental", "planned"]
    static let defaults: Set<String> = ["always", "on", "off"]

    private static let gameFeature: Set<String> = ["engine", "contract", "bridge"]

    /// Which kinds a module of a given kind may depend on (§1.5 rule 2).
    static let allowedDependencyKinds: [String: Set<String>] = [
        "gui": ["contract", "host-service"],
        "host-service": ["contract", "host-service"],
        "contract": ["contract"], // Pure contract composition; cycles remain forbidden.
        "bridge": [],
        "engine": ["contract", "bridge"],
        "identity": gameFeature,
        "display": gameFeature,
        "graphics": gameFeature,
        "controls": gameFeature,
        // Modules that run in both processes may also use host services.
        "diagnostics": gameFeature.union(["host-service"]),
        "integration": gameFeature.union(["host-service"])
    ]
}
