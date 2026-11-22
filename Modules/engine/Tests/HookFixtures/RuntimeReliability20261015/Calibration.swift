import Foundation
// __EVENT_BUS__
// __ZOOM_EVENTS__
public struct CameraZoomCancelled:EngineEvent {public init(){}}
struct Notice {let title:String;init(_ t:String,lines:[String]=[],duration:Duration = .zero){title=t}}
struct CameraSettings {var extendedReach=true}
struct Report {var result="running"}
@MainActor final class Notices {func showImportant(_ n:Notice){}}
@MainActor final class Context {let events=EventBus();let notices=Notices()}
nonisolated enum CameraMemory {static let queue=DispatchQueue(label:"fixture-camera")}
@MainActor final class PinchZoom {
 var active=false
 func sweep(outward:Bool,gestures:Int) async {active=true;try? await Task.sleep(for:.seconds(10));if !Task.isCancelled{active=false}}
 func cancel(){active=false}
}
@MainActor final class Controls {
 let context:Context
 var cameraZoomTask:Task<Void,Never>?
 var closing=false
 init(_ context:Context,_ pinch:PinchZoom) {
  self.context=context
  // __SUBSCRIBE__
 }
}
@MainActor final class CameraReachController {
 var zoomTask:Task<Void,Never>?,calibrationTask:Task<Void,Never>?
 var calibrationReport:Report?=Report(),automaticCalibration=true,calibrationGeneration=0
 enum State {case idle,checking};var calibrationState=State.checking
 var scan:Int?,calibration:Int?
 let context:Context;var settings=CameraSettings()
 static let fullZoomGestures=6
 init(_ context:Context){self.context=context}
 var canZoom:Bool {true}
 func writeCalibrationReport(){}
 func revertTrial(){}
 func scheduleSearch(restart:Bool){}
 enum Status {case notCalibrated}
 func setReport(_ status:Status,_ text:String){}
 var hotkeyText:String {"test"}
 // __CAMERA_METHODS__
}
Task { @MainActor in
 let context=Context(),pinch=PinchZoom(),controller=CameraReachController(Context())
 let camera=CameraReachController(context),controls=Controls(context,pinch)
 var requests=0;context.events.subscribe(CameraZoomRequested.self){_ in requests += 1}
 camera.zoomForCheck(firstTry:false)
 while !pinch.active {await Task.yield()}
 camera.cancelCalibration(notice:nil)
 try? await Task.sleep(for:.milliseconds(450))
 assert(!pinch.active && requests==1,"Cancelling calibration must lift its pinch and prevent the second zoom request")
 camera.zoomToReach();camera.cancelCalibration(notice:nil)
 try? await Task.sleep(for:.milliseconds(350))
 assert(requests==1,"A delayed success zoom must be cancelled when camera reach stops")
 withExtendedLifetime((controls,controller)){}
 print("PASS: calibration cancellation owns pending and active zooms")
 exit(0)
}
dispatchMain()
