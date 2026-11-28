#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import ApplicationServices
import CoreGraphics
import os

/// Keeps the visible pointer, clicks and drags inside the game while it is being played and the
/// player has shown the cursor with Alt or a middle click (`engine.confinePointer`). The captured camera cursor is already locked by
/// `CGAssociateMouseAndMouseCursorPosition`; this covers the shown cursor (the cursor key,
/// pointer maps, menus), which could otherwise leave the window and click another app or the
/// desktop in the middle of a fight. Windowed and full screen, on one display or several.
///
/// Two layers:
/// - a main-run-loop poll (and the mouse monitors) moves the cursor back to the nearest point
///   of the game's content whenever it got out. Warping never suppresses local events, so the
///   mouse never freezes at the edge;
/// - when the game already has Accessibility access, a session event tap also clamps every
///   mouse event before the window server delivers it, so even a flick-and-click faster than
///   one poll lands in the game. Without that access the tap is simply not used (no prompt).
///
/// While the pointer is confined, ⌘Tab and ⌘H are blocked too (the keybind lock); ⌘Q still quits the
/// game as in any Mac app, and Force Quit stays. Hiding or minimising the game, a native window drag or
/// resize and a full-screen transition free the pointer; other ⌘ shortcuts and ⌘-clicks stay in the game.
enum PointerConfinement {
    /// The region of the screen the pointer stays in, in AppKit screen coordinates (origin
    /// bottom-left). A resizable window keeps its 10-point resize border for AppKit, as
    /// `routesGameplayPointer` does, so the pointer stays one point further in.
    static func region(content: CGRect, resizable: Bool, fullscreen: Bool) -> CGRect? {
        guard content.minX.isFinite, content.minY.isFinite, content.width.isFinite, content.height.isFinite
        else { return nil }
        let inset: CGFloat = resizable && !fullscreen ? 11 : 1
        let region = content.standardized.insetBy(dx: inset, dy: inset)
        return region.width >= 1 && region.height >= 1 ? region : nil
    }

    /// The nearest point of `region` (edges included, the far edge one point in, since a pixel
    /// at `maxX` belongs to whatever is right of the region).
    static func clamp(_ point: CGPoint, to region: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, region.minX), region.maxX - 1),
                y: min(max(point.y, region.minY), region.maxY - 1))
    }

    static func contains(_ point: CGPoint, _ region: CGRect) -> Bool {
        clamp(point, to: region) == point
    }

    /// AppKit screen coordinates ↔ Core Graphics global coordinates (origin top-left of the
    /// first screen). The conversion is its own inverse.
    static func flipped(_ rect: CGRect, firstScreenMaxY: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: firstScreenMaxY - rect.maxY, width: rect.width, height: rect.height)
    }

    static func flipped(_ point: CGPoint, firstScreenMaxY: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: firstScreenMaxY - point.y)
    }

    /// The presentation options the keybind lock adds while the pointer is confined (2026-11-28 user request:
    /// in Alt/middle-click cursor mode, shortcuts must not switch to or hide behind another app). ⌘Tab and ⌘H
    /// are blocked; ⌘Q and Force Quit stay. AppKit raises on an invalid combination, so this only adds what
    /// it allows: process switching and hiding need the Dock hidden or auto-hidden, and full screen already
    /// auto-hides it (there nothing is added unless it does).
    static func keybindLockOptions(current: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        var next = current
        let dockHandled = current.contains(.hideDock) || current.contains(.autoHideDock)
        if !dockHandled {
            if current.contains(.fullScreen) { return [] }
            next.insert(.autoHideDock)
        }
        next.formUnion([.disableProcessSwitching, .disableHideApplication])
        return next.subtracting(current)
    }

    /// The options left after removing what the keybind lock added, kept valid: an auto-hidden menu bar
    /// needs the Dock hidden or auto-hidden, so the Dock option stays while it does.
    static func keybindUnlockOptions(current: NSApplication.PresentationOptions,
                                     added: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        var next = current.subtracting(added)
        let menuNeedsDock = next.contains(.autoHideMenuBar) || next.contains(.hideMenuBar)
        if menuNeedsDock, !next.contains(.hideDock), !next.contains(.autoHideDock), added.contains(.autoHideDock) {
            next.insert(.autoHideDock)
        }
        return next
    }

    /// Whether confinement applies now. Everything that hands the pointer back to macOS on
    /// purpose wins over it.
    /// `released`: the player showed the cursor (Alt or a middle click). Camera mode, a hidden
    /// game pointer included, is never confined or warped, so 3D rotation keeps its raw motion.
    static func applies(requested: Bool, released: Bool, active: Bool, hidden: Bool, gameKey: Bool, minimized: Bool,
                        onActiveSpace: Bool, windowInteraction: Bool, resizing: Bool, transitioning: Bool,
                        captured: Bool) -> Bool {
        requested && released && active && !hidden && gameKey && !minimized && onActiveSpace
            && !windowInteraction && !resizing && !transitioning && !captured
    }
}

/// The optional session event tap. Its callback runs on the main run loop, but is a C function,
/// so the region it clamps to is kept behind a lock rather than on the main actor.
final class PointerConfinementTap: @unchecked Sendable {
    /// Core Graphics coordinates; nil while confinement does not apply.
    private let region = OSAllocatedUnfairLock<CGRect?>(initialState: nil)
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    var isInstalled: Bool { port != nil }

    func setRegion(_ rect: CGRect?) { region.withLock { $0 = rect } }

    /// Installs the tap if this process may filter input (Accessibility). Never prompts.
    @MainActor func installIfAllowed() {
        guard port == nil, AXIsProcessTrusted() else { return }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                    .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                    .otherMouseDown, .otherMouseUp, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: pointerConfinementTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.port = port
        self.source = source
    }

    @MainActor func uninstall() {
        setRegion(nil)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMachPortInvalidate(port) }
        source = nil
        port = nil
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return
        }
        guard let rect = region.withLock({ $0 }) else { return }
        let location = event.location
        let clamped = PointerConfinement.clamp(location, to: rect)
        if clamped != location { event.location = clamped }
    }
}

private func pointerConfinementTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                           userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let userInfo {
        Unmanaged<PointerConfinementTap>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
    }
    return Unmanaged.passUnretained(event)
}
#endif
