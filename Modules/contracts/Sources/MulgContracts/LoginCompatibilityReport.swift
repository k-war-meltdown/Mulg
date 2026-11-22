import Foundation

/// Provider payloads, callback URLs, OAuth state and credentials never enter this report.
public struct LoginCompatibilityReport: Codable, Sendable {
    public struct Event: Codable, Sendable {
        public let provider: String
        public let state: String
        public let errorDomain: String?
        public let errorCode: Int?
        public let date: Date

        public init(provider: String, state: String, errorDomain: String?, errorCode: Int?) {
            self.provider = provider
            self.state = state
            self.errorDomain = errorDomain
            self.errorCode = errorCode
            date = .now
        }
    }

    public let bundleIdentifier: String
    public let processIdentifier: Int32
    public let launchSessionID: UUID
    public let enabled: Bool
    public let removedAppleSignInCapability: Bool
    public let declaredCallbackSchemeCount: Int
    public let installedHooks: [String]
    public var events: [Event]

    public init(bundleIdentifier: String, launchSessionID: UUID, enabled: Bool, removedAppleSignInCapability: Bool,
                declaredCallbackSchemeCount: Int, installedHooks: [String]) {
        self.bundleIdentifier = bundleIdentifier
        processIdentifier = ProcessInfo.processInfo.processIdentifier
        self.launchSessionID = launchSessionID
        self.enabled = enabled
        self.removedAppleSignInCapability = removedAppleSignInCapability
        self.declaredCallbackSchemeCount = declaredCallbackSchemeCount
        self.installedHooks = installedHooks
        events = []
    }

    public mutating func append(_ event: Event) {
        events.append(event)
        if events.count > 8 { events.removeFirst(events.count - 8) }
    }
}
