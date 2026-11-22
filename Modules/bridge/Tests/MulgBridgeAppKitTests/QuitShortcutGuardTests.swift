#if os(macOS) && !targetEnvironment(macCatalyst)
import Testing
@testable import MulgBridgeAppKit

@Suite("Quit shortcut guard")
struct QuitShortcutGuardTests {
    @Test("One ⌘Q warns, a second within two seconds quits, a late or held one warns again")
    func doublePress() {
        var guardState = QuitShortcutGuard()
        #expect(guardState.press(at: 10, isRepeat: false) == .warn)
        #expect(guardState.press(at: 10.2, isRepeat: true) == .ignore) // holding ⌘Q
        #expect(guardState.press(at: 11.5, isRepeat: false) == .quit)
        #expect(guardState.press(at: 20, isRepeat: false) == .warn)
        #expect(guardState.press(at: 23, isRepeat: false) == .warn) // too late: armed again
        #expect(guardState.press(at: 24, isRepeat: false) == .quit)
    }
}
#endif
