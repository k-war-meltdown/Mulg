import Foundation
import os
nonisolated enum FixtureThreads { static func started(_ generation: Int) {} }
nonisolated enum CameraMemory {
 nonisolated(unsafe) static var values:[UInt64:UInt32]=[:]
 nonisolated(unsafe) static var onRead:(()->Void)?
 enum SwapResult {case swapped,different}
 static func read(_ address:UInt64)->UInt32? {
  let value=values[address];let callback=onRead;onRead=nil;callback?();return value
 }
 static func swap(_ address:UInt64,expected:UInt32,replacement:UInt32)->SwapResult {
  guard values[address]==expected else{return .different};values[address]=replacement;return .swapped
 }
}
nonisolated enum CameraCalibrationPlan {
 // __PASSED_LIMIT__
}
// __HOLD__
let far=Float(6.5).bitPattern,raised=Float(10).bitPattern
func target(_ address:UInt64)->CameraHold.Target {.init(addresses:[address],farthestBits:far,raisedBits:raised,watched:[])}
let hold=CameraHold()
let scenario=CommandLine.arguments[1]
if scenario=="inward" {
 CameraMemory.values=[1:far];hold.start(target(1));_=hold.tick(1)
 CameraMemory.onRead={hold.playerZoomed(outward:false)}
 _=hold.tick(1);_=hold.tick(1)
 assert(CameraMemory.values[1]==far,"A completed inward zoom must prevent a captured outward tick writing afterward")
} else {
 CameraMemory.values=[1:far,2:far];hold.start(target(1),force:true)
 CameraMemory.onRead={hold.start(target(2),force:true)}
 _=hold.tick(1)
 assert(CameraMemory.values[1]==far && hold.statistics.ticks==0,"A replaced target cannot receive a stale write or old statistics")
 _=hold.tick(2)
 assert(CameraMemory.values[2]==raised && hold.statistics.ticks==1)
 CameraMemory.values[2]=far
 CameraMemory.onRead={hold.setRaised(Float(12).bitPattern)}
 _=hold.tick(2)
 assert(CameraMemory.values[2]==Float(12).bitPattern,"Live reach tuning must not write an obsolete distance")
}
hold.stop()
print("PASS: camera hold \(scenario)")
