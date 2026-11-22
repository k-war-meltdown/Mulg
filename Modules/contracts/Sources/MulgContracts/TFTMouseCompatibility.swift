import Foundation

/// A backend choice tied to TFT's app identity, never a particular game build.
public enum TFTMouseCompatibility {
    public static func applies(to identifier: String) -> Bool {
        let base = "com.riotgames.league.teamfighttactics"
        return identifier == base || identifier.hasPrefix(base + ".")
    }
}
