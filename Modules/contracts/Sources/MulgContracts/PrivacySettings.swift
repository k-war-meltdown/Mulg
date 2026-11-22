import Foundation

/// What a game may ask the Mac for (engine module, `privacy.*`). Off answers the game the way an
/// iPad does when the player taps "Don't Allow", before macOS shows any dialog, so the game is
/// never asked twice and nothing is prompted. Every IPA starts with all of them off.
public struct PrivacySettings: Codable, Sendable, Equatable {
    public var microphone = false
    public var camera = false
    public var photos = false
    public var location = false

    public init() {}

    enum CodingKeys: String, CodingKey { case microphone, camera, photos, location }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PrivacySettings()
        microphone = try c.value(.microphone, default: d.microphone)
        camera = try c.value(.camera, default: d.camera)
        photos = try c.value(.photos, default: d.photos)
        location = try c.value(.location, default: d.location)
    }
}
