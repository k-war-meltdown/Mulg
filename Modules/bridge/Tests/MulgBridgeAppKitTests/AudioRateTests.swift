#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import CoreAudio
@testable import MulgBridgeAppKit
import Testing

@Suite("iPad-native output rate")
struct AudioRateTests {
    private func ranges(_ rates: [Double]) -> [AudioValueRange] { rates.map { AudioValueRange(mMinimum: $0, mMaximum: $0) } }

    @Test("48 kHz when the device offers it, whatever it runs now")
    func prefers48k() {
        #expect(AudioOutputController.chooseRate(requested: 48_000, baseline: 192_000,
                                                 ranges: ranges([44_100, 48_000, 96_000, 192_000])) == 48_000)
    }

    @Test("A DAC without 48 kHz gets 44.1 kHz, not its 192 kHz")
    func fallsBackTo44k() {
        #expect(AudioOutputController.chooseRate(requested: 48_000, baseline: 192_000,
                                                 ranges: ranges([44_100, 88_200, 176_400, 192_000])) == 44_100)
    }

    @Test("A device already running the rate needs no advertised range; one with neither keeps the request")
    func edges() {
        #expect(AudioOutputController.chooseRate(requested: 48_000, baseline: 48_000, ranges: []) == 48_000)
        #expect(AudioOutputController.chooseRate(requested: 48_000, baseline: 96_000, ranges: ranges([96_000, 192_000])) == nil)
        #expect(AudioOutputController.chooseRate(requested: 0, baseline: 96_000, ranges: []) == 96_000)
        // A continuous range counts too.
        #expect(AudioOutputController.chooseRate(requested: 48_000, baseline: 96_000,
                                                 ranges: [AudioValueRange(mMinimum: 8_000, mMaximum: 192_000)]) == 48_000)
    }
}
#endif
