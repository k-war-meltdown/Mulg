#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import Testing
@testable import MulgBridgeAppKit

@Suite("Full-screen shape")
struct FullScreenShapeTests {
    @Test("A fixed shape fits inside the screen with bars, never stretched")
    func fits() {
        // 16:9 on a 16:10 MacBook screen: bars above and below.
        #expect(AppKitBridge.fullScreenSize(proposed: NSSize(width: 1512, height: 945), shape: NSSize(width: 3840, height: 2160))
                == NSSize(width: 1512, height: 850))
        // 4:3 iPad on a 16:9 monitor: bars left and right.
        #expect(AppKitBridge.fullScreenSize(proposed: NSSize(width: 1920, height: 1080), shape: NSSize(width: 2752, height: 2064))
                == NSSize(width: 1440, height: 1080))
        // No shape, or a shape that already matches: the proposed size.
        #expect(AppKitBridge.fullScreenSize(proposed: NSSize(width: 1920, height: 1080), shape: nil) == NSSize(width: 1920, height: 1080))
        #expect(AppKitBridge.fullScreenSize(proposed: NSSize(width: 1920, height: 1080), shape: NSSize(width: 3840, height: 2160))
                == NSSize(width: 1920, height: 1080))
    }
}
#endif
