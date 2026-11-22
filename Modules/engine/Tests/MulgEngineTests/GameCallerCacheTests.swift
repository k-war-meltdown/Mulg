#if os(macOS)
import Foundation
import MulgEngineHooks
import Testing

/// A function of this test image, as a game function would be.
private let localFunction: @convention(c) () -> Void = {}

@Suite("Game caller classification", .serialized)
struct GameCallerCacheTests {
    private static let systemSymbols = ["malloc", "objc_msgSend", "CFRunLoopRun", "dispatch_async", "NSLog",
                                        "pthread_create", "open", "dladdr", "mach_absolute_time", "CFStringCreateCopy"]

    private func systemAddresses() throws -> [UnsafeRawPointer] {
        try Self.systemSymbols.map { name in
            try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)).assumingMemoryBound(to: UInt8.self)
        }.map { UnsafeRawPointer($0) }
    }

    private var localAddress: UnsafeRawPointer { unsafeBitCast(localFunction, to: UnsafeRawPointer.self) }

    @Test("The code range of an address is the executable segment that holds it, also in the shared cache")
    func rangesContainTheirAddresses() throws {
        for address in try systemAddresses() + [localAddress] {
            var info = Dl_info()
            #expect(dladdr(address, &info) != 0)
            var start: UInt = 0, end: UInt = 0
            let header = try #require(info.dli_fbase).assumingMemoryBound(to: mach_header.self)
            #expect(mulg_engine_code_range(header, address, &start, &end))
            #expect(start <= UInt(bitPattern: address) && UInt(bitPattern: address) < end)
        }
        // An address outside every executable segment is not cached.
        var start: UInt = 0, end: UInt = 0
        let header = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc"))
        var info = Dl_info()
        _ = dladdr(header, &info)
        #expect(!mulg_engine_code_range(try #require(info.dli_fbase).assumingMemoryBound(to: mach_header.self),
                                        UnsafeRawPointer(bitPattern: 0x10), &start, &end))
    }

    @Test("Cached answers match a fresh classification, for game and system callers alike")
    func cachedAnswersAreStable() throws {
        var info = Dl_info()
        #expect(dladdr(localAddress, &info) != 0)
        let image = String(cString: try #require(info.dli_fname))
        let bundle = (image as NSString).deletingLastPathComponent
        defer { mulg_engine_set_game_callers_for_testing("/nonexistent-mulg-game", false) }
        mulg_engine_set_game_callers_for_testing(bundle, true)

        let system = try systemAddresses()
        for _ in 0..<3 {
            #expect(mulg_engine_is_game_caller(localAddress))
            for address in system { #expect(!mulg_engine_is_game_caller(address)) }
        }
        #expect(!mulg_engine_is_game_caller(nil))

        // Alternating call sites used to defeat the one-entry cache and call dladdr every time.
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for index in 0..<200_000 {
                _ = mulg_engine_is_game_caller(index % 2 == 0 ? localAddress : system[index % system.count])
            }
        }
        #expect(elapsed < .milliseconds(500))
    }

    @Test("Different sites in one executable segment retain classification and invalidate together")
    func segmentAnswersInvalidateTogether() throws {
        var info = Dl_info()
        #expect(dladdr(localAddress, &info) != 0)
        let image = String(cString: try #require(info.dli_fname))
        let bundle = (image as NSString).deletingLastPathComponent
        var start: UInt = 0, end: UInt = 0
        let header = try #require(info.dli_fbase).assumingMemoryBound(to: mach_header.self)
        #expect(mulg_engine_code_range(header, localAddress, &start, &end))
        let sites = try [start, UInt(bitPattern: localAddress), end - 4].map {
            try #require(UnsafeRawPointer(bitPattern: $0))
        }
        let system = try systemAddresses()
        defer { mulg_engine_set_game_callers_for_testing("/nonexistent-mulg-game", false) }
        for game in [true, false, true, false] {
            // The test hook uses the same generation invalidation as an image unload.
            mulg_engine_set_game_callers_for_testing(game ? bundle : "/nonexistent-mulg-game", game)
            for _ in 0..<3 {
                for site in sites + sites.reversed() { #expect(mulg_engine_is_game_caller(site) == game) }
                for address in system { #expect(!mulg_engine_is_game_caller(address)) }
                #expect(mulg_engine_is_game_caller(localAddress) == game)
            }
        }
    }
}
#endif
