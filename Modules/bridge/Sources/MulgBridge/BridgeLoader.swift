import Foundation

/// Loads the AppKit bridge bundle from the game's PlugIns folder.
public enum BridgeLoader {
    /// Bundle name inside the game's `PlugIns` folder.
    public static let bundleName = "MulgBridge"

    public enum LoadError: Error, Equatable, CustomStringConvertible {
        case noPlugInsFolder
        case bundleMissing
        case wrongPrincipalClass
        case incompatibleRuntime

        public var description: String {
            switch self {
            case .noPlugInsFolder: "The game has no PlugIns folder"
            case .bundleMissing: "The \(BridgeLoader.bundleName).bundle is missing; re-inject the game"
            case .wrongPrincipalClass: "The bridge bundle does not provide a MacBridge"
            case .incompatibleRuntime: "The bridge was built for a different runtime; re-inject the game"
            }
        }
    }

    @MainActor
    public static func load(from plugInsFolder: URL? = Bundle.main.builtInPlugInsURL,
                            expectedVersion: String? = nil, expectedProtocol: Int? = nil) -> Result<any MacBridge, LoadError> {
        guard let plugInsFolder else {
            return .failure(.noPlugInsFolder)
        }
        let url = plugInsFolder.appendingPathComponent(bundleName).appendingPathExtension("bundle")
        if let expectedVersion, let expectedProtocol {
            guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Resources/MulgRuntime.json")),
                  let stamp = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  stamp["version"] as? String == expectedVersion,
                  stamp["runtimeProtocol"] as? Int == expectedProtocol else { return .failure(.incompatibleRuntime) }
        }
        guard let bundle = Bundle(url: url), bundle.load() else {
            return .failure(.bundleMissing)
        }
        guard let bridgeClass = bundle.principalClass as? any MacBridge.Type else {
            return .failure(.wrongPrincipalClass)
        }
        return .success(bridgeClass.init())
    }
}
