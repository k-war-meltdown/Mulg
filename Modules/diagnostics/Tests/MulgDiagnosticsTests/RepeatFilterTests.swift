import Foundation
import MulgContracts
@testable import MulgDiagnostics
import Testing

@Suite("Repeated debug log lines")
struct RepeatFilterTests {
    private let second: UInt64 = 1_000_000_000

    private func spam(_ index: Int) -> String { "unused fragment binding in render encoder at Sampler index \(index)." }

    @Test("Lines that differ only in numbers count as one line: a few are kept, the rest are counted")
    func numbersAreIgnored() {
        var filter = RepeatFilter()
        var summaries: [RepeatFilter.Summary] = []
        let kept = (0..<10).filter { filter.admit("console", spam($0), now: second, summaries: &summaries) }
        #expect(kept == [0, 1, 2])
        #expect(summaries.isEmpty)
        // The window ends: the next line of the same shape reports what was left out.
        #expect(filter.admit("console", spam(11), now: 3 * second, summaries: &summaries))
        #expect(summaries == [.init(category: "console", count: 7, example: spam(3))])
    }

    @Test("Hex addresses are numbers too, so the Metal buffer dumps collapse")
    func addressesAreIgnored() {
        var filter = RepeatFilter()
        var summaries: [RepeatFilter.Summary] = []
        let lines = ["0x7b13725dc0", "0x7b12861dc0", "0x7bbe33ddc0", "0x7bbe33ddd0"]
            .map { "redundant setting of <AGXG18GFamilyBuffer: \($0)>" }
        let admitted = lines.map { filter.admit("log", $0, now: second, summaries: &summaries) }
        #expect(admitted == [true, true, true, false])
    }

    @Test("Anything that looks like a problem is always kept, however often it repeats")
    func problemsAreNeverCounted() {
        var filter = RepeatFilter()
        var summaries: [RepeatFilter.Summary] = []
        for index in 0..<50 {
            #expect(filter.admit("console", "Invalid Resource at index \(index)", now: second, summaries: &summaries))
            #expect(filter.admit("log", "ERROR com.apple.coreaudio: Failed to create converter \(index)", now: second, summaries: &summaries))
        }
        #expect(summaries.isEmpty)
    }

    @Test("Different shapes and different categories are counted separately")
    func shapesAreIndependent() {
        var filter = RepeatFilter()
        var summaries: [RepeatFilter.Summary] = []
        for _ in 0..<5 { _ = filter.admit("console", "alpha 1", now: second, summaries: &summaries) }
        #expect(filter.admit("console", "beta 1", now: second, summaries: &summaries))
        #expect(filter.admit("log", "alpha 1", now: second, summaries: &summaries))
        #expect(filter.drain(now: second, force: true) == [.init(category: "console", count: 2, example: "alpha 1")])
    }

    @Test("A flood that stopped is still reported: when its window ends, and when the log closes")
    func drainReportsAStoppedFlood() {
        var filter = RepeatFilter()
        var summaries: [RepeatFilter.Summary] = []
        for index in 0..<6 { _ = filter.admit("console", spam(index), now: second, summaries: &summaries) }
        #expect(filter.drain(now: second + second / 2).isEmpty)
        #expect(filter.drain(now: 3 * second) == [.init(category: "console", count: 3, example: spam(3))])
        #expect(filter.drain(now: 5 * second, force: true).isEmpty)
    }

    @Test("More shapes than slots in one window never loses a count or crashes")
    func manyShapesStayBounded() {
        var filter = RepeatFilter()
        var summaries: [RepeatFilter.Summary] = []
        var written = 0
        for shape in 0..<1_000 {
            for _ in 0..<5 {
                if filter.admit("console", "shape-\(shape)-word x", now: second, summaries: &summaries) { written += 1 }
            }
        }
        let counted = summaries.reduce(0) { $0 + $1.count } + filter.drain(now: second, force: true).reduce(0) { $0 + $1.count }
        #expect(written + counted == 5_000)
    }

    @Test("The debug log keeps a flood as a few lines and one count, and everything else untouched")
    func logFileIsCompact() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let debugger = try #require(Debugger(directory: directory, settings: DiagnosticsSettings()))
        for index in 0..<500 { debugger.log("console", spam(index)) }
        debugger.log("cpu", "The main thread has not answered for 2.0 s.")
        debugger.log("console", "Invalid Resource: index 9")
        debugger.close()
        let log = try String(contentsOf: directory.appendingPathComponent(Debugger.fileName), encoding: .utf8)
        let lines = log.split(separator: "\n")
        #expect(lines.count <= 8)
        #expect(log.contains("(497 more lines like this, numbers aside)"))
        #expect(log.contains("[cpu] The main thread has not answered"))
        #expect(log.contains("[console] Invalid Resource: index 9"))
    }
}
