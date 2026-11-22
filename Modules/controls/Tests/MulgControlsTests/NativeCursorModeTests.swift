import Testing
@testable import MulgControls

@Suite("Native game cursor toggles")
struct NativeCursorModeTests {
    private let cursorKeys: Set<UInt16> = [0x3A, 0x3D]

    @Test func modifierTapSwitchesBothDirectionsWithoutAKeymap() {
        var mode = NativeCursorMode()
        #expect(!mode.released)
        for expected in [true, false] {
            let result1 = mode.modifier(code: 0x3A, pressed: true, cursorKeys: cursorKeys, commandDown: false)
            #expect(!result1)
            let result2 = mode.modifier(code: 0x3A, pressed: false, cursorKeys: cursorKeys, commandDown: false)
            #expect(result2)
            #expect(mode.released == expected)
        }
    }

    @Test func middlePressTogglesOnceAndOtherButtonsLeaveItAlone() {
        var mode = NativeCursorMode()
        let result3 = mode.mouse(button: 2, pressed: true)
        #expect(result3)
        #expect(mode.released)
        let result4 = mode.mouse(button: 2, pressed: true)
        #expect(!result4)
        for button in [0, 1, 3] {
            let result5 = mode.mouse(button: button, pressed: true)
            #expect(!result5)
            let result6 = mode.mouse(button: button, pressed: false)
            #expect(!result6)
        }
        #expect(mode.released)
        let result7 = mode.mouse(button: 2, pressed: false)
        #expect(!result7)
        let result8 = mode.mouse(button: 2, pressed: true)
        #expect(result8)
        #expect(!mode.released)
    }

    @Test func twoOptionKeysProduceOneToggleAndSystemChordsDoNotToggle() {
        var mode = NativeCursorMode()
        _ = mode.modifier(code: 0x3A, pressed: true, cursorKeys: cursorKeys, commandDown: false)
        _ = mode.modifier(code: 0x3D, pressed: true, cursorKeys: cursorKeys, commandDown: false)
        let result9 = mode.modifier(code: 0x3A, pressed: false, cursorKeys: cursorKeys, commandDown: false)
        #expect(!result9)
        let result10 = mode.modifier(code: 0x3D, pressed: false, cursorKeys: cursorKeys, commandDown: false)
        #expect(result10)
        #expect(mode.released)
        _ = mode.modifier(code: 0x3A, pressed: true, cursorKeys: cursorKeys, commandDown: true)
        let result11 = mode.modifier(code: 0x3A, pressed: false, cursorKeys: cursorKeys, commandDown: false)
        #expect(!result11)
        #expect(mode.released)
    }

    @Test func focusLossCancelsAnIncompletePressWithoutChangingCursorChoice() {
        var mode = NativeCursorMode()
        _ = mode.modifier(code: 0x3A, pressed: true, cursorKeys: cursorKeys, commandDown: false)
        mode.focusLost()
        let result12 = mode.modifier(code: 0x3A, pressed: false, cursorKeys: cursorKeys, commandDown: false)
        #expect(!result12)
        #expect(!mode.released)
    }
}
