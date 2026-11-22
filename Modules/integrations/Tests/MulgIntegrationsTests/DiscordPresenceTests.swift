import Foundation
@testable import MulgIntegrations
import MulgContracts
import Testing

@Suite("Discord presence")
struct DiscordPresenceTests {
    @Test func frameIsOpcodeLengthThenJSON() throws {
        let data = DiscordPresence.frame(DiscordPresence.handshake, ["v": 1])
        let json = Data("{\"v\":1}".utf8)
        #expect(Array(data.prefix(8)) == [0, 0, 0, 0, UInt8(json.count), 0, 0, 0])
        #expect(data.dropFirst(8) == json)
    }

    @Test func activityMatchesTheOldRuntime() throws {
        var custom = DiscordActivitySettings()
        let plain = DiscordPresence.activity(custom, gameName: "Game", artwork: "art", start: Date(timeIntervalSince1970: 2))
        #expect(plain["details"] as? String == "Playing Game")
        #expect(plain["state"] as? String == "Powered by Mulg")
        #expect(plain["assets"] as? [String: String] == ["large_image": "art"])
        #expect((plain["timestamps"] as? [String: Int])?["start"] == 2000)

        custom.details = "x"
        custom.state = "Raid"
        let own = DiscordPresence.activity(custom, gameName: "Game", artwork: nil, start: .now)
        #expect(own["details"] as? String == "x ")
        #expect(own["assets"] as? [String: String] == ["small_text": "Powered by Mulg", "large_text": "Powered by Mulg"])
    }
}
