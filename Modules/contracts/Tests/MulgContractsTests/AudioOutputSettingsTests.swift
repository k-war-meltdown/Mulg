import Foundation
@testable import MulgContracts
import Testing

@Suite("Audio output settings")
struct AudioOutputSettingsTests {
    @Test("Games always run at the iPad's 48 kHz; an old selectable rate in a settings file is ignored")
    func rateIsNotASetting() throws {
        #expect(AudioOutputSettings.iPadSampleRate == 48_000)
        let old = Data(#"{"rate":"hz192000","depth":"bits24","restoreOnExit":false}"#.utf8)
        let settings = try JSONDecoder().decode(AudioOutputSettings.self, from: old)
        #expect(settings.depth == .bits24 && settings.restoreOnExit == false)
        let encoded = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        #expect(!encoded.contains("rate"))
    }
}
