import Foundation
import CoreGraphics
import Darwin
import Synchronization
// __PRODUCTION__
let mouse = RawMouse()
assert(mouse.add(dx: 12, dy: -4))
assert(!mouse.add(dx: .nan, dy: 9))
assert(!mouse.add(dx: 3, dy: .infinity))
let valid = mouse.take()
assert(valid == CGVector(dx: 12, dy: -4), "A malformed packet must not poison already queued movement")
assert(mouse.add(dx: .greatestFiniteMagnitude, dy: 1))
assert(!mouse.add(dx: .greatestFiniteMagnitude, dy: 1))
assert(mouse.take() == CGVector(dx: CGFloat.greatestFiniteMagnitude, dy: 1))
assert(mouse.add(dx: 1, dy: 2) && mouse.take() == CGVector(dx: 1, dy: 2))
print("PASS: malformed and overflowing raw packets preserve valid accumulated input")
