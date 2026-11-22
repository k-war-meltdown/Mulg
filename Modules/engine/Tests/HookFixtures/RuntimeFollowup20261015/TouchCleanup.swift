import Foundation
import CoreGraphics
enum TouchPhase { case began, moved, ended }
enum NativePhase { case began, moved, ended, cancelled }
@MainActor final class UIView {}
@MainActor final class UIWindow { func hitTest(_ point: CGPoint, with: Any?) -> UIView? { UIView() } }
@MainActor enum GameViewport {
    struct Surface {
        let window: UIWindow
        var multiplier: CGFloat = 1
        var isValid: Bool { true }; var geometryIsCurrent: Bool { true }
        func windowPoint(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * multiplier, y: point.y * multiplier) }
    }
    static let shared = Viewport()
    final class Viewport {
        var multiplier: CGFloat = 1
        func captureSurface(in window: UIWindow?) -> Surface? { window.map { Surface(window: $0, multiplier: multiplier) } }
    }
}
var cancelled = 0, nextID = 0
@MainActor func mulg_touch_inject(_ id: Int, _ point: CGPoint, _ phase: NativePhase, _ window: UIWindow?, _ view: UIView?) -> Int {
    if !point.x.isFinite || !point.y.isFinite { return -1 }
    if phase == .cancelled { cancelled += 1; return -1 }
    if phase == .ended { return -1 }
    if phase == .began { nextID += 1; return nextID }; return id
}
@MainActor final class Injector {
    struct Contact { let surface: GameViewport.Surface; var localPoint: CGPoint; var windowPoint: CGPoint }
    var owners: [Int: Contact] = [:], suspended = false, geometryCancellations = 0
    func keyWindow() -> UIWindow? { UIWindow() }
    // __PRODUCTION__
}
Task { @MainActor in
    let injector = Injector(); var id: Int?
    injector.touch(&id, at: CGPoint(x: 10, y: 20), phase: .began)
    injector.touch(&id, at: CGPoint(x: CGFloat.nan, y: 20), phase: .ended)
    assert(id == nil && injector.owners.isEmpty && cancelled == 1, "Invalid release must cancel the last valid native contact")
    GameViewport.shared.multiplier = 1000
    injector.touch(&id, at: CGPoint(x: 10, y: 20), phase: .began)
    injector.touch(&id, at: CGPoint(x: CGFloat.greatestFiniteMagnitude, y: 20), phase: .moved)
    assert(id == nil && injector.owners.isEmpty && cancelled == 2)
    GameViewport.shared.multiplier = 1
    injector.touch(&id, at: CGPoint(x: 10, y: 20), phase: .began)
    injector.touch(&id, at: CGPoint(x: CGFloat.nan, y: 20), phase: .began)
    assert(id != nil && cancelled == 2)
    injector.touch(&id, at: CGPoint(x: 30, y: 40), phase: .ended)
    assert(id == nil)
    print("PASS: invalid or overflowing touch coordinates release ownership without losing native cleanup")
    exit(0)
}
dispatchMain()
