import Foundation
import MulgIdentityHooks
import Testing

/// Hook cost budget (PLAN.md §16.4 X3): the work a hook adds on every call stays tiny.
/// Budgets are generous so slow CI machines pass; a regression of 10× or more still fails.
@Suite("Hook cost", .serialized)
struct HookCostTests {
    private func averageNanoseconds(iterations: Int = 100_000, _ body: () -> Void) -> Double {
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<iterations { body() }
        }
        let parts = elapsed.components
        return (Double(parts.seconds) * 1e9 + Double(parts.attoseconds) / 1e9) / Double(iterations)
    }

    @Test("Copying the spoofed model into a sysctl buffer costs under 1 µs")
    func sysctlCopy() {
        var buffer = [CChar](repeating: 0, count: 64)
        var length = buffer.count
        let cost = averageNanoseconds {
            length = buffer.count
            _ = mulg_sysctl_copy_string("iPad17,3", &buffer, &length)
        }
        #expect(cost < 1_000)
    }

    @Test("The memory cap costs under 1 µs")
    func memoryCap() {
        mulg_identity_configure_memory_limit(12 * 1_073_741_824)
        defer { mulg_identity_configure_memory_limit(0) }
        var sink: UInt64 = 0
        let cost = averageNanoseconds { sink &+= mulg_identity_limited_memory(36 * 1_073_741_824) }
        #expect(cost < 1_000)
        #expect(sink > 0)
    }
}
