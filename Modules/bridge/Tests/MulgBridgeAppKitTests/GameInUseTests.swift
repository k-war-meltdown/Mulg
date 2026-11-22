#if os(macOS) && !targetEnvironment(macCatalyst)
import Testing
@testable import MulgBridgeAppKit

@Suite("Game in use (mute when not in focus)")
struct GameInUseTests {
    private let shown = (minimised: false, visible: true, unoccluded: true)

    @Test("In use only while active, not hidden, and a game window is really visible")
    func rules() {
        #expect(AppKitBridge.inUse(active: true, hidden: false, windows: [shown]))
        #expect(!AppKitBridge.inUse(active: false, hidden: false, windows: [shown]))   // another app in front
        #expect(!AppKitBridge.inUse(active: true, hidden: true, windows: [shown]))     // ⌘H
        #expect(!AppKitBridge.inUse(active: true, hidden: false, windows: [(true, false, false)])) // minimised
        #expect(!AppKitBridge.inUse(active: true, hidden: false, windows: [(false, true, false)])) // covered, other Space
        #expect(!AppKitBridge.inUse(active: true, hidden: false, windows: []))         // no game window
    }

    @Test("One visible game window is enough when another is minimised")
    func severalWindows() {
        #expect(AppKitBridge.inUse(active: true, hidden: false, windows: [(true, false, false), shown]))
    }
}
#endif
