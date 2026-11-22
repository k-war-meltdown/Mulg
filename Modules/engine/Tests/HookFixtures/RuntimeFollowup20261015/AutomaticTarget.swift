import Foundation
// __PRODUCTION__
var detector = AutomaticMetalFX(target: 120)
var time = 0.0, index = 0
@MainActor func sample() -> Bool { time += index % 2 == 0 ? 0.025 : 0.045; index += 1; return detector.record(presentedTime: time) }
// Finish initial settling, then collect four slow buckets at the old target.
while time < AutomaticMetalFX.settleTime + 8.1 { assert(!sample()) }
detector.target = 60
let changed = time
while time < changed + 8.1 { assert(!sample(), "A new target must not inherit old slow buckets") }
var triggered = false
while time < changed + 10.5 { triggered = sample() || triggered }
assert(triggered, "Automatic detection must still work after enough new observations")
print("PASS: frame-target changes discard prior pacing evidence and preserve later detection")
