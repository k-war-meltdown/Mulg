import Testing
import MulgEngineHooks

@Suite("Converted app memory compatibility")
struct MemoryCompatibilityTests {
    private let gib: UInt64 = 1_073_741_824

    @Test("An unsupported zero still provides allocator capacity without an identity profile")
    func allocatorBootstrap() {
        let answer = mulg_engine_available_memory_answer(0, true, 16 * gib, gib, 8 * gib, 0)
        #expect(answer == 8 * gib)
        // The crashing pool allocator rounds its address range to a power of two,
        // then divides by its 64 KiB page * 2048 entries per bucket. Zero produced
        // zero buckets and an unmapped table; this budget covers ordinary pools.
        let bytesPerBucket: UInt64 = 65_536 * 2048
        #expect(answer / bytesPerBucket > 0)
    }

    @Test("Native framework calls and supported native values pass through")
    func nativeAnswers() {
        #expect(mulg_engine_available_memory_answer(0, false, 16 * gib, gib, 8 * gib, 4 * gib) == 0)
        #expect(mulg_engine_available_memory_answer(3 * gib, true, 16 * gib, gib, 8 * gib, 2 * gib) == 3 * gib)
        #expect(mulg_engine_available_memory_answer(3 * gib, false, 0, 0, 0, 0) == 3 * gib)
    }

    @Test("Real pressure and exhausted device budgets remain zero")
    func exhaustion() {
        #expect(mulg_engine_available_memory_answer(0, true, 16 * gib, gib, 0, 0) == 0)
        #expect(mulg_engine_available_memory_answer(0, true, 16 * gib, 4 * gib, 8 * gib, 4 * gib) == 0)
        #expect(mulg_engine_available_memory_answer(0, true, 16 * gib, 17 * gib, 8 * gib, 0) == 0)
        #expect(mulg_engine_available_memory_answer(0, true, 0, 0, 8 * gib, 0) == 0)
    }

    @Test("Live caps bound cached headroom without raising Mac capacity")
    func capsAndOverflow() {
        #expect(mulg_engine_available_memory_answer(0, true, 16 * gib, 3 * gib, 12 * gib, 8 * gib) == 5 * gib)
        #expect(mulg_engine_available_memory_answer(0, true, 16 * gib, 3 * gib, 12 * gib, 0) == 12 * gib)
        #expect(mulg_engine_available_memory_answer(0, true, 16 * gib, 3 * gib, 12 * gib, 32 * gib) == 12 * gib)
        #expect(mulg_engine_available_memory_answer(0, true, UInt64.max, UInt64.max - 4, UInt64.max, 0) == 4)
    }
}
