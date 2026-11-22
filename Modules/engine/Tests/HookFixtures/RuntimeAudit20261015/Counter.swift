import Foundation
enum Counter {
    // __PRODUCTION__
}
var previous: UInt64 = 1000
assert(Counter.bytesWritten(since: &previous, current: 0) == nil && previous == 1000)
assert(Counter.bytesWritten(since: &previous, current: 1100) == 100)
assert(Counter.bytesWritten(since: &previous, current: 100) == 0 && previous == 100)
assert(Counter.bytesWritten(since: &previous, current: 100) == 0)
assert(Counter.bytesWritten(since: &previous, current: 100 + (6 << 20)) == 6 << 20)
previous = UInt64.max
assert(Counter.bytesWritten(since: &previous, current: 2) == 0)
previous = 0
assert(Counter.bytesWritten(since: &previous, current: 0) == 0)
print("PASS: counter resets do not become false background downloads; normal deltas survive")
