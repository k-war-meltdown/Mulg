import Foundation
@MainActor class UIScene:NSObject {
 enum ActivationState {case foregroundActive,foregroundInactive,background,unattached}
 var activationState=ActivationState.foregroundActive
 var delegate:NSObject?=NSObject()
nonisolated static let willDeactivateNotification=Notification.Name("scene-resign"),didEnterBackgroundNotification=Notification.Name("scene-background"),willEnterForegroundNotification=Notification.Name("scene-foreground"),didActivateNotification=Notification.Name("scene-active")
}
@MainActor final class UIWindowScene:UIScene {var windows:[UIWindow]=[];nonisolated static let didDisconnectNotification=Notification.Name("scene-disconnect")}
@MainActor final class UIWindow:NSObject {var isKeyWindow=true;var windowScene:UIWindowScene?}
@MainActor final class UIApplication:NSObject {
 static let shared=UIApplication()
 var connectedScenes:[UIScene]=[];var delegate:NSObject?=NSObject()
nonisolated static let willResignActiveNotification=Notification.Name("app-resign"),didEnterBackgroundNotification=Notification.Name("app-background"),willEnterForegroundNotification=Notification.Name("app-foreground"),didBecomeActiveNotification=Notification.Name("app-active")
}
@MainActor final class GameViewport {static let shared=GameViewport();var window:UIWindow?}
@MainActor func mulg_engine_set_keep_active(_ enabled:Bool){}
@MainActor func mulg_engine_clear_lifecycle_state(_ object:AnyObject){}
@MainActor func mulg_engine_set_lifecycle_state(_ object:AnyObject,_ state:Int){}
@MainActor func mulg_engine_notify_game_lifecycle(_ name:Notification.Name,_ object:AnyObject){}
var calls:[String]=[]
var onDelegate:(()->Void)?
@MainActor func mulg_engine_call_game_lifecycle_delegate(_ delegate:AnyObject?,_ selector:Selector,_ object:AnyObject) {
 calls.append(NSStringFromSelector(selector))
 let callback=onDelegate;onDelegate=nil;callback?()
}
// __LIFECYCLE__
Task { @MainActor in
 let scene=UIWindowScene(),window=UIWindow();scene.windows=[window];window.windowScene=scene
 UIApplication.shared.connectedScenes=[scene];GameViewport.shared.window=window
 let lifecycle=GameLifecycle()
 onDelegate={lifecycle.end()}
 lifecycle.windowChanged(focused:false,onScreen:true)
 try? await Task.sleep(for:.milliseconds(450))
 assert(calls.filter{$0=="sceneWillResignActive:"}.count==1,"Reentrant shutdown must not resend resign-active")
 assert(calls.filter{$0=="sceneDidEnterBackground:"}.count==1 && lifecycle.state == .background,"Shutdown must finish in background even when requested by a lifecycle callback")
 lifecycle.end();assert(calls.count==2)
 print("PASS: reentrant lifecycle shutdown is serialized and idempotent")
 exit(0)
}
dispatchMain()
