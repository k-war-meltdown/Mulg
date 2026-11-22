import Foundation

/// Collapses floods of near-identical lines, which are most of a Metal validation log
/// ("unused fragment binding in render encoder at Sampler index 7", repeated for every index and
/// every draw; 640,000 lines in 70 seconds). Lines that differ only in numbers and addresses count
/// as the same line. A shape is written `kept` times per `window`; the rest are counted, and one
/// summary line takes their place. Anything that looks like a problem is always kept.
///
/// Pure value logic with no clock or file of its own, so it is cheap to test: the caller supplies
/// `now` (nanoseconds) and holds whatever lock it needs.
struct RepeatFilter {
    /// What one expired window suppressed.
    struct Summary: Equatable {
        let category: String
        let count: Int
        let example: String
    }

    static let kept = 3
    static let window: UInt64 = 1_000_000_000
    private static let slotCount = 128
    private static let probes = 8

    private struct Slot {
        var key: UInt64 = 0
        var start: UInt64 = 0
        var written = 0
        var suppressed = 0
        var category = ""
        var example = ""
        var used = false
    }
    private var slots = [Slot](repeating: Slot(), count: slotCount)

    /// True when the line should be written. What an expired window of the same shape suppressed is
    /// appended to `summaries`, to be written before the line. A category keeps its own shapes.
    mutating func admit(_ category: String, _ text: String, now: UInt64, summaries: inout [Summary]) -> Bool {
        var text = text
        text.makeContiguousUTF8()  // OSLog messages arrive bridged from Objective-C
        if Self.looksLikeProblem(text) { return true }
        let key = Self.shape(text, seed: Self.shape(category))
        let index = slot(for: key, now: now, summaries: &summaries)
        if slots[index].used, slots[index].key == key, now &- slots[index].start < Self.window {
            if slots[index].written < Self.kept {
                slots[index].written += 1
                return true
            }
            if slots[index].suppressed == 0 { slots[index].example = text }
            slots[index].suppressed += 1
            return false
        }
        // New shape, or its window ran out: summarise the old one and start a new window.
        if let summary = summary(of: index) { summaries.append(summary) }
        slots[index] = Slot(key: key, start: now, written: 1, suppressed: 0, category: category, example: "", used: true)
        return true
    }

    /// The suppressed counts of windows that ended (all of them with `force`, at close), so a
    /// flood that stopped is still reported.
    mutating func drain(now: UInt64, force: Bool = false) -> [Summary] {
        var summaries: [Summary] = []
        for index in slots.indices where slots[index].used && slots[index].suppressed > 0
            && (force || now &- slots[index].start >= Self.window) {
            summaries.append(summary(of: index)!)
            slots[index].suppressed = 0
            slots[index].example = ""
        }
        return summaries
    }

    private func summary(of index: Int) -> Summary? {
        slots[index].suppressed > 0
            ? Summary(category: slots[index].category, count: slots[index].suppressed, example: slots[index].example)
            : nil
    }

    /// The slot for `key`: its own, a free one, or the one idle longest (summarised first).
    private mutating func slot(for key: UInt64, now: UInt64, summaries: inout [Summary]) -> Int {
        let first = Int(key % UInt64(Self.slotCount))
        var oldest = first
        for probe in 0..<Self.probes {
            let index = (first + probe) % Self.slotCount
            if !slots[index].used || slots[index].key == key { return index }
            if slots[index].start < slots[oldest].start { oldest = index }
        }
        if let summary = summary(of: oldest) { summaries.append(summary) }
        slots[oldest] = Slot()
        return oldest
    }

    /// A 64-bit shape of the line: decimal numbers and 0x… addresses collapse to one placeholder,
    /// everything else is hashed as it is. No allocation.
    static func shape(_ text: String, seed: UInt64 = 0) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 ^ seed
        var inNumber = false, inHex = false
        var previous: UInt8 = 0
        for byte in text.utf8 {
            defer { previous = byte }
            if inHex {
                if byte.isHexDigit { continue }
                inHex = false
            }
            if byte >= 0x30 && byte <= 0x39 {
                if !inNumber {
                    inNumber = true
                    hash = (hash ^ 0x23) &* 0x100_0000_01b3
                }
                continue
            }
            if byte == 0x78, previous == 0x30, inNumber {  // "0x": the hex digits are part of the number
                inHex = true
                continue
            }
            inNumber = false
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return hash
    }

    /// Words that mark a line worth keeping every time, whatever its shape.
    private static let problemWords: [[UInt8]] = ["error", "fail", "fault", "assert", "exception", "crash", "invalid"]
        .map { Array($0.utf8) }

    static func looksLikeProblem(_ text: String) -> Bool {
        text.utf8.withContiguousStorageIfAvailable { bytes in
            problemWords.contains { contains(bytes, $0) }
        } ?? true  // not contiguous UTF-8: keep it rather than guess
    }

    /// ASCII case-insensitive substring search over raw bytes.
    private static func contains(_ bytes: UnsafeBufferPointer<UInt8>, _ word: [UInt8]) -> Bool {
        guard bytes.count >= word.count else { return false }
        for start in 0...(bytes.count - word.count) {
            var matched = true
            for offset in 0..<word.count where bytes[start + offset] | 0x20 != word[offset] {
                matched = false
                break
            }
            if matched { return true }
        }
        return false
    }
}

private extension UInt8 {
    var isHexDigit: Bool {
        (self >= 0x30 && self <= 0x39) || (self >= 0x61 && self <= 0x66) || (self >= 0x41 && self <= 0x46)
    }
}
