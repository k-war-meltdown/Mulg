#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Testing
@testable import MulgBridgeAppKit

@Suite("Native modifier and gesture edges") @MainActor
struct ModifierGestureTests {
    @Test func releasingOneSideWhileTheOtherIsHeld() {
        for (left, right, flag, leftBit, rightBit) in [
            (UInt16(0x38), UInt16(0x3C), NSEvent.ModifierFlags.shift, UInt(2), UInt(4)),
            (0x3B, 0x3E, .control, 1, 0x2000), (0x3A, 0x3D, .option, 0x20, 0x40),
            (0x37, 0x36, .command, 8, 0x10)
        ] {
            let both = NSEvent.ModifierFlags(rawValue: flag.rawValue | leftBit | rightBit)
            let rightOnly = NSEvent.ModifierFlags(rawValue: flag.rawValue | rightBit)
            #expect(AppKitBridge.modifierPressed(code: left, flags: both) == true)
            #expect(AppKitBridge.modifierPressed(code: right, flags: both) == true)
            #expect(AppKitBridge.modifierPressed(code: left, flags: rightOnly) == false)
            #expect(AppKitBridge.modifierPressed(code: right, flags: rightOnly) == true)
            let leftOnly = NSEvent.ModifierFlags(rawValue: flag.rawValue | leftBit)
            #expect(AppKitBridge.modifierPressed(code: right, flags: leftOnly) == false)
            #expect(AppKitBridge.modifierPressed(code: left, flags: leftOnly) == true)
        }
        #expect(AppKitBridge.modifierPressed(code: 0x38, flags: .shift) == true)
        #expect(AppKitBridge.modifierPressed(code: 0x38, flags: []) == false)
        #expect(AppKitBridge.modifierPressed(code: 0x00, flags: []) == nil)
    }

    @Test func cancelledGestureIsNotAnEnd() {
        #expect(AppKitBridge.phaseCode(.cancelled) == 4)
        #expect(AppKitBridge.phaseCode(.ended) == 3)
        #expect(AppKitBridge.phaseCode(.began) == 1)
        #expect(AppKitBridge.phaseCode(.changed) == 2)
    }
}
#endif
