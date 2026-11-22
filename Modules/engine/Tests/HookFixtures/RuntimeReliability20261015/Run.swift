import Foundation
let root=URL(fileURLWithPath:CommandLine.arguments[1]),fixtures=URL(fileURLWithPath:CommandLine.arguments[2])
let out=URL(fileURLWithPath:CommandLine.arguments[3]),name=CommandLine.arguments[4]
let scenario=CommandLine.arguments.count>5 ? CommandLine.arguments[5]:"default"
try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
func read(_ path:String)throws->String {try String(contentsOf:root.appendingPathComponent(path),encoding:.utf8)}
func stripped(_ source:String)->String {source.components(separatedBy:.newlines).filter{!$0.hasPrefix("import ")}.joined(separator:"\n")}
func body(_ source:String,_ signature:String)throws->String {
 guard let start=source.range(of:signature)?.lowerBound,let brace=source[start...].firstIndex(of:"{") else {throw NSError(domain:"Missing production symbol: "+signature,code:1)}
 var index=brace,depth=0
 repeat {if source[index]=="{"{depth += 1};if source[index]=="}"{depth -= 1};index=source.index(after:index)}while depth>0
 return String(source[start..<index])
}
var code=try String(contentsOf:fixtures.appendingPathComponent(name + (name=="Priority" || name=="Motion" || name=="FrameRate" || name=="TouchRelease" ? ".m":".swift")),encoding:.utf8)
func replace(_ key:String,_ value:String){code=code.replacingOccurrences(of:"// __"+key+"__",with:value)}
let isC=["Priority","Motion","FrameRate","TouchRelease"].contains(name)
switch name {
case "Hold":
 var source=stripped(try read("Modules/camera/Sources/MulgCamera/CameraHold.swift"))
 let thread=try body(source,"Thread.detachNewThread")
 source=source.replacingOccurrences(of:thread,with:"FixtureThreads.started(generation)").replacingOccurrences(of:"private func tick",with:"func tick")
 let settings = try body(read("Modules/contracts/Sources/MulgContracts/CameraReach.swift"), "public struct CameraSettings")
 let defaults = stripped(try read("Modules/contracts/Sources/MulgContracts/DecodingDefaults.swift"))
 replace("HOLD",settings + "\n" + defaults + "\n" + source)
 replace("PASSED_LIMIT",try body(read("Modules/camera/Sources/MulgCamera/CameraCalibrationPlan.swift"),"static func passedLimit"))
case "Calibration":
 replace("EVENT_BUS",stripped(try read("Modules/engine/Sources/MulgEngine/EventBus.swift")))
 replace("ZOOM_EVENTS",try body(read("Modules/engine/Sources/MulgEngine/Events.swift"),"public struct CameraZoomRequested"))
 let camera=try read("Modules/camera/Sources/MulgCamera/CameraReachController+Calibration.swift")
 var methods=""
 for signature in ["func cancelCalibration(","private func zoomForCheck(","func requestZoom(","func zoomToReach("] {methods += try body(camera,signature).replacingOccurrences(of:"private func",with:"func") + "\n"}
 replace("CAMERA_METHODS",methods)
 let controls=try read("Modules/controls/Sources/MulgControls/ControlsModule.swift")
 var wiring=try body(controls,"context.events.subscribe(CameraZoomRequested.self)")
 if controls.contains("context.events.subscribe(CameraZoomCancelled.self)"){wiring += "\n" + (try body(controls,"context.events.subscribe(CameraZoomCancelled.self)"))}
 replace("SUBSCRIBE",wiring)
case "Lifecycle":
 replace("LIFECYCLE",stripped(try read("Modules/engine/Sources/MulgEngine/GameLifecycle.swift")).replacingOccurrences(of:"#if canImport(UIKit) && !os(watchOS)",with:"#if true"))
case "ControllerAliases":
 replace("CONTROLLER_INPUT",stripped(try read("Modules/controls/Sources/MulgControls/ControllerInput.swift")))
case "Priority": replace("PRIORITY_INCLUDE","#include \""+root.appendingPathComponent("Modules/engine/Sources/MulgEngineHooks/MulgThreadPriority.m").path+"\"")
case "Motion": replace("MOTION_INCLUDE","#include \""+root.appendingPathComponent("Modules/controls/Sources/MulgControlsHooks/MulgMotionHooks.m").path+"\"")
case "FrameRate": replace("FRAME_RATE_INCLUDE","#include \""+root.appendingPathComponent("Modules/display/Sources/MulgDisplayHooks/MulgFrameRateHooks.m").path+"\"")
case "TouchRelease":
 let source=try read("Modules/controls/Sources/MulgControlsHooks/MulgTouchInjection.m")
 let start=source.range(of:"@interface MulgTouchContact")!.lowerBound,end=source.range(of:"static NSMutableDictionary<NSNumber *, MulgTouchContact *> *mulg_contacts;")!.lowerBound
 replace("CONTACTS",String(source[start..<end]))
 replace("INJECT",try body(source,"NSInteger mulg_touch_inject("))
 replace("BEGIN_ORDER",try body(source,"static BOOL mulg_begin_waits_for_end("))
 let begin=source.range(of:"if (!contact.beganDelivered) {\n                sample.phase")!.lowerBound
 let finish=source.range(of:"[samples addObject:sample];")!.lowerBound
 replace("SNAPSHOT",String(source[begin..<finish]))
default: fatalError("Unknown fixture")
}
func run(_ program:String,_ args:[String])throws->Int32 {
 let process=Process();process.executableURL=URL(fileURLWithPath:program);process.arguments=args
 try process.run();process.waitUntilExit();return process.terminationStatus
}
let file=out.appendingPathComponent(name+(isC ? ".m":".swift"))
try code.write(to:file,atomically:true,encoding:.utf8)
if isC {
 var args=["clang","-fobjc-arc","-fblocks","-Wno-incompatible-pointer-types","-Wno-objc-method-access","-I",root.appendingPathComponent("Modules/engine/Sources/MulgEngineHooks/include").path,"-I",root.appendingPathComponent("Modules/controls/Sources/MulgControlsHooks/include").path,"-I",root.appendingPathComponent("Modules/display/Sources/MulgDisplayHooks/include").path,file.path]
 if name=="Motion"{args += [root.appendingPathComponent("Modules/controls/Sources/MulgControlsHooks/MulgMotionMath.m").path]}
 let binary=out.appendingPathComponent(name)
 args += ["-framework","Foundation","-framework","CoreGraphics","-framework","CoreMotion","-framework","QuartzCore","-o",binary.path]
 let status=try run("/usr/bin/xcrun",args)
 guard status==0 else {exit(status)}
 exit(try run(binary.path,[scenario]))
} else {
 exit(try run("/usr/bin/xcrun",["swift","-swift-version","6","-module-cache-path",out.appendingPathComponent("cache").path,file.path,scenario]))
}
