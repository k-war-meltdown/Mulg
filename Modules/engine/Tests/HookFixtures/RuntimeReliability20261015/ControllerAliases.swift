import Foundation
import CoreGraphics
import GameController
import Synchronization
public struct ControllerStickSettings:Equatable {var deadzone=0.0,exponent=1.0;public init(){}}
enum StickResponse {static func shape(x:Double,y:Double,settings:ControllerStickSettings)->(x:Double,y:Double){(x,y)}}
enum DispatchPriority {case normal,camera,draggable}
enum ControlInputSource {case controller}
@MainActor public final class ActionDispatcher {
 var buttons:[String:(Bool)->Void]=[:]
 func hasMapping(for key:String)->Bool {buttons[key] != nil}
 func layer(heldBy key:String)->Int? {nil}
 func motionPriority(for key:String)->DispatchPriority? {nil}
 func withInputTransaction(_ body:()->Void){body()}
 @discardableResult func dispatch(key:String,pressed:Bool,source:ControlInputSource)->Bool {buttons[key]?(pressed);return buttons[key] != nil}
 @discardableResult func dispatch(key:String,x:CGFloat,y:CGFloat)->Bool {false}
}
// __CONTROLLER_INPUT__
final class AliasedButton:GCControllerButtonInput {
 var advertised:Set<String>=[]
 var pressedState=true
 override var aliases:Set<String> {advertised}
 override var isPressed:Bool {pressedState}
}
Task { @MainActor in
 let dispatcher=ActionDispatcher(),input=ControllerInput(dispatcher:dispatcher,virtualController:nil)
 let controller=GCController.withExtendedGamepad();input.attach(controller)
 let identity=ObjectIdentifier(controller),token=input.token(for:controller)!
 let button=AliasedButton();var edges:[Bool]=[]
 dispatcher.buttons["Button A"]={edges.append($0)}
 for index in 0..<50 {
  button.advertised=["Button A","Vendor \(index)","Alternate \(index)"]
  input.changed(ControllerInput.Sample.capture(button)!,controller:identity,generation:token)
  input.changed(.button("Button A",false),controller:identity,generation:token)
 }
 assert(edges.count==100,"Set iteration order must not drop canonical controller bindings")
 dispatcher.buttons.removeAll();var vendorEdges=0
 dispatcher.buttons["Cross"]={if $0{vendorEdges += 1}}
 button.advertised=["Button A","Cross"]
 input.changed(ControllerInput.Sample.capture(button)!,controller:identity,generation:token)
 assert(vendorEdges==1,"A map explicitly using a vendor alias must remain supported")
 var releases:[String]=[];input.onButton={name,pressed in if !pressed{releases.append(name)};return true}
 dispatcher.buttons["Button A"]={_ in};button.pressedState=false
 input.changed(ControllerInput.Sample.capture(button)!,controller:identity,generation:token)
 assert(releases==["Cross"],"Alias changes must not steal a held button's release")
 input.focusLost()
 print("PASS: controller aliases resolve consistently and preserve vendor maps")
 exit(0)
}
dispatchMain()
