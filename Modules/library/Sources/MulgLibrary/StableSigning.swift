import Foundation

/// The designated requirement Mulg gives every ad hoc signature it makes: the bundle identifier.
///
/// macOS keeps "Allow" answers (privacy permissions, keychain "Always Allow", opening the app) per
/// designated requirement. A plain ad hoc signature's requirement is its exact code hash, so
/// every Mulg update, and every re-sign of a game (a runtime or bridge update), made it a new app
/// and macOS asked again. With the identifier as requirement it asks once per game.
///
/// The signature stays ad hoc: a game's sandbox container only opens for the kind of signature
/// that created it (build 881 broke every game with a certificate). Tested on 2026-10-06 with a
/// sandboxed probe app: the container kept working after the switch and across rebuilds.
public enum StableSigning {
    /// `codesign` arguments setting the requirement; empty for an identifier codesign would
    /// misread (only letters, digits, dots, hyphens and underscores are used).
    public static func requirementArguments(bundleIdentifier: String?) -> [String] {
        guard let identifier = bundleIdentifier, !identifier.isEmpty,
              identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }) else { return [] }
        return ["-r=designated => identifier \"\(identifier)\""]
    }

    /// The bundle identifier of the app at `url`, from its Info.plist (iOS or macOS layout).
    public static func bundleIdentifier(ofApp url: URL) -> String? {
        for plist in [url.appendingPathComponent("Info.plist"), url.appendingPathComponent("Contents/Info.plist")] {
            if let data = try? Data(contentsOf: plist),
               let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let identifier = info["CFBundleIdentifier"] as? String { return identifier }
        }
        return nil
    }
}
