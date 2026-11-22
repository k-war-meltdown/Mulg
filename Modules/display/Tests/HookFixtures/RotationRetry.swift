
public struct MenuCommand { public init(id:String,title:String,key:String,modifiers:[Modifier],section:String,submenu:String) {} }
public enum Modifier {case command,shift}
enum UIInterfaceOrientation {case landscapeLeft,portrait,landscapeRight,portraitUpsideDown}
struct UIInterfaceOrientationMask {static let all=Self()}
@MainActor class UIView {var window:UIWindow?;var backgroundColor:Color?}
enum Color {case black}
@MainActor class UIWindow {var rootViewController:UIViewController?;var isKeyWindow=true}
@MainActor class UIScene {}
@MainActor class UIWindowScene:UIScene {var windows:[UIWindow]=[]}
@MainActor class UIApplication {static let shared=UIApplication();var connectedScenes:[UIScene]=[]}
enum ModalStyle {case fullScreen}
@MainActor class UIViewController {
 var view=UIView();var viewIfLoaded:UIView? {view}
 var presentedViewController:UIViewController?;var presentingViewController:UIViewController?
 var isBeingDismissed=false;var isBeingPresented=false;var transitionCoordinator:AnyObject?;var modalPresentationStyle=ModalStyle.fullScreen
 init(nibName:String?,bundle:Bundle?) {}
 required init?(coder:NSCoder) {}
 var preferredInterfaceOrientationForPresentation:UIInterfaceOrientation {.landscapeLeft}
 var supportedInterfaceOrientations:UIInterfaceOrientationMask {.all}
 func viewDidLoad() {}
 func viewDidAppear(_ animated:Bool) {}
 func dismiss(animated:Bool) {}
 static var presentations:[UIInterfaceOrientation]=[]
 func present(_ controller:UIViewController,animated:Bool) {Self.presentations.append(controller.preferredInterfaceOrientationForPresentation)}
}
Task { @MainActor in
 DisplayRotation.apply(0)
 await Task.yield()
 let scene=UIWindowScene(),window=UIWindow(),presenter=UIViewController(nibName:nil,bundle:nil)
 window.rootViewController=presenter;presenter.view.window=window;scene.windows=[window];UIApplication.shared.connectedScenes=[scene]
 DisplayRotation.apply(1)
 try? await Task.sleep(for:.milliseconds(250))
 let ok=UIViewController.presentations == [.portrait]
 print("\(ok ? "PASS":"FAIL"): newer display rotation supersedes a no-window retry")
 exit(ok ? 0:1)
}
dispatchMain()
