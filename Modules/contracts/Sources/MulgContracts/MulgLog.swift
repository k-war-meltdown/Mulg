import Foundation
import os

/// One system logger per module (PLAN.md §12 #9): subsystem = the app, category = the
/// module id, so logs filter by module in Console and in the diagnostics export.
public enum MulgLog {
    public static let subsystem = "io.mulg"

    public static func logger(_ module: ModuleID) -> Logger {
        Logger(subsystem: subsystem, category: module.rawValue)
    }

    /// Signposts for timing start-up and hook costs (PLAN.md §16.4 X3).
    public static func signposter(_ module: ModuleID) -> OSSignposter {
        OSSignposter(subsystem: subsystem, category: module.rawValue)
    }
}
