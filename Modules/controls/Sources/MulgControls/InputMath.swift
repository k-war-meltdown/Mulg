import CoreGraphics
import Foundation
import MulgContracts

/// Where the Mac cursor is on the game's screen (upstream TouchscreenMouseEventAdapter.cursorPos).
public enum CursorMapping {
    /// - Parameters:
    ///   - mouse: cursor position in window coordinates (AppKit: origin bottom-left).
    ///   - window: the window frame (only the size matters).
    ///   - screen: the screen the game sees.
    ///   - fullscreen: whether the window is full screen (the game is letterboxed and centred).
    ///   - resizable: whether edges are for resizing (clicks within 10 points are not mapped).
    /// - Returns: the point in game coordinates, or nil when the cursor is outside the game.
    public static func gamePoint(mouse: CGPoint, window: CGRect, screen: CGSize,
                                 fullscreen: Bool, resizable: Bool) -> CGPoint? {
        // A zero screen (a scene being set up or torn down) would turn every point into NaN.
        guard mouse.x.isFinite, mouse.y.isFinite,
              window.width.isFinite, window.height.isFinite, screen.width.isFinite, screen.height.isFinite,
              window.width >= 1, window.height >= 1, screen.width > 0, screen.height > 0 else { return nil }
        var point = mouse
        if resizable && !fullscreen {
            let margin: CGFloat = 10
            if point.x < margin || point.x > window.width - margin
                || point.y < margin || point.y > window.height - margin {
                return nil
            }
        }
        // Keep the aspect ratio: scale by the larger ratio.
        let rate = max(screen.width / window.width, screen.height / window.height)
        if fullscreen {
            point.y -= (window.height - screen.height / rate) / 2
        }
        point.y *= rate
        point.y = screen.height - point.y
        // Above the game: the window's title bar and traffic lights.
        if point.y < 0 {
            return nil
        }
        point.x -= (window.width - screen.width / rate) / 2
        point.x *= rate
        guard point.x >= 0, point.x <= screen.width, point.y >= 0, point.y <= screen.height else { return nil }
        return point
    }
}

/// Mouse movement → virtual thumbstick deflection (PLAN.md §14.1).
///
/// A mouse sets a position, a stick sets a speed. Each mouse movement pushes the stick in the
/// movement's direction through a response curve; between movements the stick decays towards
/// the centre, so it stops when the mouse stops.
public struct StickCurve: Sendable, Equatable {
    public let settings: StickCurveSettings
    public private(set) var x: Double = 0
    public private(set) var y: Double = 0

    public init(settings: StickCurveSettings) {
        self.settings = settings
    }

    /// Applies a mouse movement (points). AppKit's vertical axis grows downwards; a stick's
    /// grows upwards, so dy is inverted.
    public mutating func push(dx: Double, dy: Double) {
        x = Self.clamp(x + shaped(dx * settings.sensitivity))
        y = Self.clamp(y + shaped(-dy * settings.sensitivity))
    }

    /// One frame without movement: moves the stick towards the centre.
    public mutating func decay() {
        let keep = max(0, min(1, 1 - settings.decay))
        x *= keep
        y *= keep
        if abs(x) < settings.deadzone { x = 0 }
        if abs(y) < settings.deadzone { y = 0 }
    }

    public var isCentred: Bool { x == 0 && y == 0 }

    func shaped(_ value: Double) -> Double {
        let magnitude = abs(value)
        guard magnitude >= settings.deadzone else { return 0 }
        return (value < 0 ? -1 : 1) * pow(min(magnitude, 1), max(0.1, settings.exponent))
    }

    static func clamp(_ value: Double) -> Double {
        max(-1, min(1, value))
    }
}

/// Mouse movement → device rotation for the virtual gyro (PLAN.md §14.3).
///
/// The virtual iPad is held upright in landscape (see MulgMotionMath.m): the device X axis
/// points up and Y points across the screen. Turning right is a clockwise turn about "up",
/// which is negative about X; looking up tilts about Y.
public enum GyroMapping {
    public struct Rotation: Sendable, Equatable {
        public let x: Double
        public let y: Double
        public let z: Double
    }

    public static func rotation(mouseDX dx: Double, mouseDY dy: Double, settings: GyroSettings) -> Rotation {
        let yaw = dx * settings.mouseYawSensitivity
        var pitch = dy * settings.mousePitchSensitivity
        if settings.invertPitch { pitch = -pitch }
        return Rotation(x: -yaw, y: -pitch, z: 0)
    }

    /// Held-key rotation (degrees per second → radians per second): arrows for yaw and pitch,
    /// Q/E-style keys for roll.
    public static func steadyRate(yawDirection: Int, pitchDirection: Int, rollDirection: Int,
                                  settings: GyroSettings) -> Rotation {
        let speed = settings.keyRotationSpeed * .pi / 180
        var pitch = Double(pitchDirection) * speed
        if settings.invertPitch { pitch = -pitch }
        return Rotation(x: -Double(yawDirection) * speed, y: -pitch, z: Double(rollDirection) * speed)
    }
}

/// A real controller's thumbstick through the player's deadzone and response curve
/// (PLAN.md §13.2 accessibility). Radial, so diagonals keep their direction.
public enum StickResponse {
    public static func shape(x: Double, y: Double, settings: ControllerStickSettings) -> (x: Double, y: Double) {
        // The defaults pass the stick through untouched, as before the setting existed.
        guard settings.deadzone > 0 || settings.exponent != 1 else { return (x, y) }
        let deadzone = max(0, min(0.95, settings.deadzone))
        let magnitude = (x * x + y * y).squareRoot()
        guard magnitude > deadzone else { return (0, 0) }
        let shaped = pow(min((magnitude - deadzone) / (1 - deadzone), 1), max(0.1, settings.exponent))
        return (x / magnitude * shaped, y / magnitude * shaped)
    }
}
