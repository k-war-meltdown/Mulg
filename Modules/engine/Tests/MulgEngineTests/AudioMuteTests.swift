import AudioToolbox
import MulgContracts
import MulgEngineHooks
import Testing

@Suite("Mute when not in focus", .serialized)
struct AudioMuteTests {
    @Test("Off by default, and saved per game")
    func offByDefault() throws {
        #expect(EngineSettings().muteWhenUnfocused == false)
        var settings = EngineSettings()
        settings.muteWhenUnfocused = true
        #expect(try JSONDecoder().decode(EngineSettings.self, from: JSONEncoder().encode(settings)).muteWhenUnfocused)
    }

    @Test("An output queue goes silent while muted and gets the game's own volume back")
    func queueKeepsTheGamesVolume() throws {
        defer { mulg_engine_set_audio_muted(false) }
        var format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                                 mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var queue: AudioQueueRef?
        try #require(AudioQueueNewOutput(&format, { _, _, _ in }, nil, nil, nil, 0, &queue) == noErr)
        let created = try #require(queue)
        defer { _ = mulg_engine_audio_queue_dispose_for_testing(UnsafeMutableRawPointer(created)) }
        // In a game the creation hook does this; a test bundle is loaded too late to be interposed.
        mulg_engine_audio_mute_track_queue_for_testing(UnsafeMutableRawPointer(created))
        func volume() -> Float32 {
            var value: AudioQueueParameterValue = -1
            AudioQueueGetParameter(created, kAudioQueueParam_Volume, &value)
            return value
        }
        _ = mulg_engine_audio_queue_set_volume_for_testing(UnsafeMutableRawPointer(created), 0.5)
        mulg_engine_set_audio_muted(true)
        #expect(mulg_engine_audio_muted())
        #expect(volume() == 0)
        _ = mulg_engine_audio_queue_set_volume_for_testing(UnsafeMutableRawPointer(created), 0.8) // the game, while muted
        #expect(volume() == 0)
        mulg_engine_set_audio_muted(false)
        #expect(abs(volume() - 0.8) < 0.0001)
    }
}
