import CoreGraphics
import Foundation
import MulgBridge
import MulgControlsHooks
import MulgEngine
#if canImport(UIKit) && !os(watchOS)
import UIKit
import QuartzCore

/// Event-driven pointer input. Game views with a checked coordinate-bearing contact
/// method receive absolute clicks; the virtual mouse remains for other game input.
@MainActor
final class TFTMouseBridge {
    private let bridge: any MacBridge
    private var held: Set<Int> = []
    private var gameContact: NSObject?
    private weak var gameContactView: UIView?
    private var gameContactPoint: CGPoint?
    private var cursorReleased = true
    private let cursor = CAShapeLayer()

    init(bridge: any MacBridge) {
        self.bridge = bridge
        let path = UIBezierPath()
        path.move(to: .zero)
        for point in [CGPoint(x: 0, y: 19), CGPoint(x: 5, y: 14), CGPoint(x: 9, y: 22),
                      CGPoint(x: 13, y: 20), CGPoint(x: 9, y: 12), CGPoint(x: 17, y: 12)] {
            path.addLine(to: point)
        }
        path.close()
        cursor.path = path.cgPath
        cursor.fillColor = UIColor.white.cgColor
        cursor.strokeColor = UIColor.black.cgColor
        cursor.lineWidth = 1.5
        cursor.zPosition = 10_000
        cursor.bounds = CGRect(x: 0, y: 0, width: 20, height: 24)
        cursor.anchorPoint = .zero
        cursor.isHidden = true
        cursor.actions = ["position": NSNull(), "hidden": NSNull(), "contents": NSNull()]
    }

    func setCursorReleased(_ released: Bool) {
        cursorReleased = released
        updateCursor()
    }

    private func gamePoint(in window: UIWindow) -> CGPoint? {
        guard !window.isHidden,
              let point = CursorMapping.gamePoint(mouse: bridge.mousePoint, window: bridge.windowFrame,
                  screen: window.bounds.size, fullscreen: bridge.isFullscreen, resizable: false),
              window.bounds.contains(point) else { return nil }
        return point
    }

    private func updateCursor() {
        guard cursorReleased, bridge.isTextInputActive != true,
              let window = GameViewport.shared.window,
              let point = gamePoint(in: window) else { cursor.isHidden = true; return }
        // A layer cannot intercept hits or become a responder; pointer position stays native.
        if cursor.superlayer !== window.layer { cursor.removeFromSuperlayer(); window.layer.addSublayer(cursor) }
        cursor.contentsScale = window.screen.scale
        cursor.position = point
        cursor.isHidden = false
    }

    func move(_ dx: CGFloat, _ dy: CGFloat) {
        updateCursor()
        guard bridge.isTextInputActive != true else { return }
        if let gameContact {
            if let point = contactPoint(in: gameContactView) {
                mulg_controls_game_touch_move(gameContact, point)
                gameContactPoint = point
            }
            return
        }
        _ = mulg_controls_tft_mouse_move(Float(dx), Float(-dy))
    }

    func button(_ number: Int, pressed: Bool) -> Bool {
        updateCursor()
        if number == 0, !pressed, let gameContact {
            mulg_controls_game_touch_end(gameContact,
                contactPoint(in: gameContactView) ?? gameContactPoint ?? .zero)
            self.gameContact = nil
            gameContactView = nil
            gameContactPoint = nil
            return true
        }
        // A routed press always keeps its release, including outside the game view.
        if !pressed, held.remove(number) != nil {
            _ = mulg_controls_tft_mouse_button(number, false)
            return true
        }
        guard pressed, number != 2, bridge.isTextInputActive != true, pointsAtGameSurface() else { return false }
        if number == 0, let view = GameViewport.shared.view,
           let point = contactPoint(in: view), mulg_controls_game_touch_capable(view),
           let contact = mulg_controls_game_touch_begin(view, point) {
            gameContact = contact
            gameContactView = view
            gameContactPoint = point
            return true
        }
        guard mulg_controls_tft_mouse_button(number, true) else { return false }
        held.insert(number)
        return true
    }

    func scroll(_ dx: CGFloat, _ dy: CGFloat) -> Bool {
        guard bridge.isTextInputActive != true, pointsAtGameSurface() else { return false }
        // AppKitBridge expresses wheels in points (16 points per wheel line).
        return mulg_controls_tft_mouse_scroll(Float(dx / 16), Float(dy / 16))
    }

    func cancel() {
        if let gameContact { mulg_controls_game_touch_cancel(gameContact); self.gameContact = nil }
        gameContactView = nil
        gameContactPoint = nil
        held.removeAll()
        cursor.isHidden = true
        mulg_controls_cancel_tft_mouse()
    }

    func stop() { cancel(); cursor.removeFromSuperlayer() }

    private func pointsAtGameSurface() -> Bool {
        let viewport = GameViewport.shared
        guard let window = viewport.window, let point = gamePoint(in: window) else { return false }
        var hit = window.hitTest(point, with: nil)
        while let view = hit {
            let name = NSStringFromClass(type(of: view))
            // Native buttons and sign-in views retain the real macOS/UIKit event stream.
            if view is UIControl || name.hasPrefix("WK") { return false }
            if view === viewport.view || view.layer is CAMetalLayer || name.hasSuffix("FIOSView") { return true }
            hit = view.superview
        }
        return false
    }

    private func contactPoint(in view: UIView?) -> CGPoint? {
        guard let view, let window = view.window, let point = gamePoint(in: window) else { return nil }
        let local = view.convert(point, from: window)
        return local.x.isFinite && local.y.isFinite && view.bounds.contains(local) ? local : nil
    }
}
#endif
