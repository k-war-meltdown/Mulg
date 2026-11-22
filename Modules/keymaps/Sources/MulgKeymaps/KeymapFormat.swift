import CoreGraphics
import Foundation

// The keymap file format, byte-compatible with upstream Mulg/MulgKit keymaps
// (Host/Mulg/Model/KeymapData.swift and Runtime/MulgKit/Editor/Models/Elements).
// One definition for both processes instead of upstream's two copies (PLAN.md §12 #2).
//
// Positions are fractions of the screen (0–1); `size` is a percentage of the screen's longer
// side. Key codes are Game Controller key codes (HID usages) for keys, and negative numbers
// for mouse and controller buttons (see KeymapKeyNames).

public enum KeymapHorizontalAnchor: String, Codable, Sendable {
    case left, center, right
}

public enum KeymapVerticalAnchor: String, Codable, Sendable {
    case top, center, bottom
}

/// Shared coordinate rule for every mapped control. Fit the reference UI uniformly into
/// the live viewport, then attach controls to horizontal and vertical anchors.
/// Only control geometry is fitted; the game continues filling the whole window.
public struct KeymapCanvas: Sendable {
    public static let referenceHeight: CGFloat = 1032
    public let referenceAspectRatio: Double
    public let viewportAspectRatio: Double
    public var scaleInHeights: CGFloat { CGFloat(min(1, viewportAspectRatio / referenceAspectRatio)) }

    public init?(referenceAspectRatio: Double, viewportAspectRatio: Double) {
        guard referenceAspectRatio.isFinite, viewportAspectRatio.isFinite,
              referenceAspectRatio > 0, viewportAspectRatio > 0 else { return nil }
        self.referenceAspectRatio = referenceAspectRatio
        self.viewportAspectRatio = viewportAspectRatio
    }

    /// Mouse deltas stay in the same logical control units through resizing/relaunching.
    public func inputScale(viewportHeight: CGFloat) -> CGFloat {
        guard viewportHeight.isFinite, viewportHeight > 0 else { return 1 }
        return viewportHeight * scaleInHeights / Self.referenceHeight
    }

    public func fitted(_ transform: KeyModelTransform) -> KeyModelTransform {
        let horizontal = transform.horizontalAnchor
            ?? (abs(transform.xCoord - 0.5) * CGFloat(referenceAspectRatio) < 0.2
                ? .center : transform.xCoord < 0.5 ? .left : .right)
        let vertical = transform.verticalAnchor
            ?? (transform.yCoord < 0.35 ? .top : transform.yCoord > 0.65 ? .bottom : .center)
        let xAnchor: CGFloat = horizontal == .left ? 0 : horizontal == .right ? 1 : 0.5
        let yAnchor: CGFloat = vertical == .top ? 0 : vertical == .bottom ? 1 : 0.5
        let x = xAnchor + (transform.xCoord - xAnchor) * CGFloat(referenceAspectRatio / viewportAspectRatio) * scaleInHeights
        let y = yAnchor + (transform.yCoord - yAnchor) * scaleInHeights
        let size = transform.size * CGFloat(max(referenceAspectRatio, 1) / max(viewportAspectRatio, 1)) * scaleInHeights
        return KeyModelTransform(size: size, xCoord: min(max(x, 0), 1), yCoord: min(max(y, 0), 1),
            horizontalAnchor: horizontal, verticalAnchor: vertical, hudSamples: transform.hudSamples, hudBaselines: transform.hudBaselines,
            widthScale: transform.widthScale, heightScale: transform.heightScale)
    }
}

public struct KeyModelTransform: Codable, Sendable, Equatable {
    public var size: CGFloat
    public var xCoord: CGFloat
    public var yCoord: CGFloat
    public var horizontalAnchor: KeymapHorizontalAnchor?
    public var verticalAnchor: KeymapVerticalAnchor?
    /// Positions observed at real HUD shapes. Unlike inferred anchors, these may describe
    /// a control that changes its layout group when the game changes aspect ratio.
    public var hudSamples: [ControlHUDSample]?
    /// Original layouts retained even when editor calibrations replace their HUD samples.
    /// This is never rebased from an already fitted or learned position.
    public var hudBaselines: [ControlHUDSample]?
    /// Independently authored editor bounds, relative to the legacy size. The touch remains
    /// at the centre; these bounds never enlarge native touches or joystick travel.
    public var widthScale: CGFloat?
    public var heightScale: CGFloat?
    public var effectiveWidthScale: CGFloat { Self.validDimension(widthScale) }
    public var effectiveHeightScale: CGFloat { Self.validDimension(heightScale) }
    private static func validDimension(_ value: CGFloat?) -> CGFloat {
        guard let value, value.isFinite, value > 0 else { return 1 }
        return min(max(value, 0.01), 100)
    }

    public init(size: CGFloat, xCoord: CGFloat, yCoord: CGFloat, horizontalAnchor: KeymapHorizontalAnchor? = nil,
                verticalAnchor: KeymapVerticalAnchor? = nil, hudSamples: [ControlHUDSample]? = nil,
                hudBaselines: [ControlHUDSample]? = nil, widthScale: CGFloat? = nil, heightScale: CGFloat? = nil) {
        self.size = size
        self.xCoord = xCoord
        self.yCoord = yCoord
        self.horizontalAnchor = horizontalAnchor
        self.verticalAnchor = verticalAnchor
        self.hudSamples = hudSamples
        self.hudBaselines = hudBaselines
        self.widthScale = widthScale
        self.heightScale = heightScale
    }
}

/// A key or button that taps a point on screen.
public struct ButtonElement: Codable, Sendable, Equatable {
    public var keyCode: Int
    public var keyName: String
    public var transform: KeyModelTransform
    /// Hold-to-toggle (PLAN.md §13.2): one press holds the touch, the next press lifts it.
    /// Absent in older keymaps, which read as a normal button.
    public var toggle: Bool?
    /// One short touch per physical press; nil retains ordinary hold behavior.
    public var tapDurationMilliseconds: Double?
    /// Draggable motion source, independent of the key/controller button that grabs it.
    public var dragMotionSource: String?

    public init(keyCode: Int, keyName: String, transform: KeyModelTransform, toggle: Bool? = nil,
                tapDurationMilliseconds: Double? = nil, dragMotionSource: String? = nil) {
        self.keyCode = keyCode
        self.keyName = keyName.isEmpty ? KeymapKeyNames.name(forKeyCode: keyCode) ?? "Btn" : keyName
        self.transform = transform
        self.toggle = toggle
        self.tapDurationMilliseconds = tapDurationMilliseconds
        self.dragMotionSource = dragMotionSource
    }

    enum CodingKeys: String, CodingKey { case keyCode, keyName, transform, toggle, tapDurationMilliseconds, dragMotionSource }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(keyCode: try c.decode(Int.self, forKey: .keyCode),
                  keyName: try c.decodeIfPresent(String.self, forKey: .keyName) ?? "",
                  transform: try c.decode(KeyModelTransform.self, forKey: .transform),
                  toggle: try c.decodeIfPresent(Bool.self, forKey: .toggle),
                  tapDurationMilliseconds: try c.decodeIfPresent(Double.self, forKey: .tapDurationMilliseconds),
                  dragMotionSource: try c.decodeIfPresent(String.self, forKey: .dragMotionSource))
    }
}

/// Upstream stores these as 0 and 1 with these exact names.
public enum JoystickMode: Int, Codable, Sendable {
    // swiftlint:disable:next identifier_name
    case FIXED = 0
    // swiftlint:disable:next identifier_name
    case FLOATING = 1
}

/// A measured neutral center and travel radius, separate from an imported map's visual size.
/// Values use the viewport where they were measured; other map transforms never rebase them.
public struct JoystickCalibration: Codable, Sendable, Equatable {
    public var transform: KeyModelTransform
    public var aspectRatio: Double

    public init?(center: CGPoint, edge: CGPoint, width: CGFloat, height: CGFloat) {
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              center.x.isFinite, center.y.isFinite, edge.x.isFinite, edge.y.isFinite,
              center.x > 0, center.y > 0, center.x < width, center.y < height else { return nil }
        let radius = hypot(edge.x - center.x, edge.y - center.y)
        let clearance = min(center.x, width - center.x, center.y, height - center.y)
        guard radius >= 4, radius <= clearance, edge.x >= 0, edge.y >= 0,
              edge.x <= width, edge.y <= height else { return nil }
        transform = KeyModelTransform(size: radius * 400 / max(width, height),
            xCoord: center.x / width, yCoord: center.y / height)
        // Resolve anchors at the measured shape once, including right-hand sticks.
        transform = transform.fitted(from: Double(width / height), to: Double(width / height))
        aspectRatio = Double(width / height)
    }

    public var isValid: Bool {
        aspectRatio.isFinite && aspectRatio > 0 && transform.size.isFinite && transform.size > 0
            && transform.xCoord.isFinite && transform.xCoord > 0 && transform.xCoord < 1
            && transform.yCoord.isFinite && transform.yCoord > 0 && transform.yCoord < 1
    }
}

/// Four keys, the mouse, or a controller thumbstick driving an on-screen joystick.
public struct JoystickElement: Codable, Sendable, Equatable {
    public var upKeyCode: Int
    public var rightKeyCode: Int
    public var downKeyCode: Int
    public var leftKeyCode: Int
    public var keyName: String
    public var transform: KeyModelTransform
    public var mode: JoystickMode?
    /// Floating-stick origin must be sampled before the drag in engines that poll input.
    public var activationDelayMilliseconds: Double?
    /// Optional precise center/radius measured inside the running game.
    public var calibration: JoystickCalibration?
    /// Measurements of the same HUD at different shapes; never rebased on resize.
    public var calibrations: [JoystickCalibration]?

    public init(upKeyCode: Int, rightKeyCode: Int, downKeyCode: Int, leftKeyCode: Int,
                keyName: String = "Keyboard", transform: KeyModelTransform, mode: JoystickMode? = .FIXED,
                activationDelayMilliseconds: Double? = nil, calibration: JoystickCalibration? = nil,
                calibrations: [JoystickCalibration]? = nil) {
        self.upKeyCode = upKeyCode
        self.rightKeyCode = rightKeyCode
        self.downKeyCode = downKeyCode
        self.leftKeyCode = leftKeyCode
        self.keyName = keyName
        self.transform = transform
        self.mode = mode
        self.activationDelayMilliseconds = activationDelayMilliseconds
        self.calibration = calibration
        self.calibrations = calibrations
    }

    enum CodingKeys: String, CodingKey {
        case upKeyCode, rightKeyCode, downKeyCode, leftKeyCode, keyName, transform, mode, activationDelayMilliseconds, calibration, calibrations
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(upKeyCode: try c.decode(Int.self, forKey: .upKeyCode),
                  rightKeyCode: try c.decode(Int.self, forKey: .rightKeyCode),
                  downKeyCode: try c.decode(Int.self, forKey: .downKeyCode),
                  leftKeyCode: try c.decode(Int.self, forKey: .leftKeyCode),
                  keyName: try c.decodeIfPresent(String.self, forKey: .keyName) ?? "Keyboard",
                  transform: try c.decode(KeyModelTransform.self, forKey: .transform),
                  mode: try c.decodeIfPresent(JoystickMode.self, forKey: .mode),
                  activationDelayMilliseconds: try c.decodeIfPresent(Double.self, forKey: .activationDelayMilliseconds),
                  calibration: try c.decodeIfPresent(JoystickCalibration.self, forKey: .calibration),
                  calibrations: try c.decodeIfPresent([JoystickCalibration].self, forKey: .calibrations))
    }

    /// Keep measurements from other shapes instead of losing them on recalibration.
    public mutating func recordCalibration(_ measurement: JoystickCalibration) {
        guard measurement.isValid else { return }
        var samples = (calibrations ?? []).filter(\.isValid)
        if let old = calibration, old.isValid,
           !samples.contains(where: { abs($0.aspectRatio - old.aspectRatio) < 0.01 }) {
            samples.append(old)
        }
        samples.removeAll { abs($0.aspectRatio - measurement.aspectRatio) < 0.01 }
        samples.append(measurement)
        // A small, bounded profile; retain the new sample and the closest older shapes.
        samples.sort { abs($0.aspectRatio - measurement.aspectRatio) < abs($1.aspectRatio - measurement.aspectRatio) }
        calibrations = Array(samples.prefix(16)).sorted { $0.aspectRatio < $1.aspectRatio }
        calibration = measurement // backward-compatible most recent measurement
    }

    /// Interpolate measurements in the current viewport, never a previously fitted map.
    /// Outside the measured range use the nearest sample's anchored reference geometry.
    public func calibratedTransform(forAspect aspect: Double) -> KeyModelTransform? {
        guard aspect.isFinite, aspect > 0 else { return nil }
        var samples = (calibrations ?? []).filter(\.isValid)
        if let calibration, calibration.isValid,
           !samples.contains(where: { abs($0.aspectRatio - calibration.aspectRatio) < 0.000001 }) {
            samples.append(calibration)
        }
        samples.sort { $0.aspectRatio < $1.aspectRatio }
        guard let first = samples.first, let last = samples.last else { return nil }
        if aspect <= first.aspectRatio { return first.transform.fitted(from: first.aspectRatio, to: aspect) }
        if aspect >= last.aspectRatio { return last.transform.fitted(from: last.aspectRatio, to: aspect) }
        guard let upperIndex = samples.firstIndex(where: { $0.aspectRatio >= aspect }), upperIndex > 0 else { return nil }
        let lower = samples[upperIndex - 1], upper = samples[upperIndex]
        let a = lower.transform.fitted(from: lower.aspectRatio, to: aspect)
        let b = upper.transform.fitted(from: upper.aspectRatio, to: aspect)
        let weight = CGFloat((aspect - lower.aspectRatio) / (upper.aspectRatio - lower.aspectRatio))
        return KeyModelTransform(size: a.size + (b.size - a.size) * weight,
            xCoord: a.xCoord + (b.xCoord - a.xCoord) * weight,
            yCoord: a.yCoord + (b.yCoord - a.yCoord) * weight,
            horizontalAnchor: a.horizontalAnchor, verticalAnchor: a.verticalAnchor)
    }

    public var effectiveMode: JoystickMode { mode ?? .FIXED }

    /// Driven by the mouse or a thumbstick rather than four keys. Upstream's rule, kept exactly:
    /// the names are "Left Thumbstick", "Right Thumbstick", "Mouse", "Keyboard" and "Dynamic",
    /// and the analog ones are those containing a "u" (Joystick.swift `isAnalog`).
    public var isAnalog: Bool {
        keyName.contains("u")
    }
}

/// An area the mouse (or a thumbstick) drags across to turn the camera.
public struct MouseAreaElement: Codable, Sendable, Equatable {
    public var keyName: String
    public var transform: KeyModelTransform

    public init(keyName: String = "Mouse", transform: KeyModelTransform) {
        self.keyName = keyName
        self.transform = transform
    }

    enum CodingKeys: String, CodingKey { case keyName, transform }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(keyName: try c.decodeIfPresent(String.self, forKey: .keyName) ?? "Mouse",
                  transform: try c.decode(KeyModelTransform.self, forKey: .transform))
    }
}

/// A key bound to a virtual-controller element (PLAN.md §14.1). Fork addition, stored under a
/// key upstream ignores.
public struct ControllerBinding: Codable, Sendable, Equatable {
    /// Game Controller key code, or a negative mouse button code.
    public var keyCode: Int
    public var element: VirtualControllerElement
    /// Additional buttons held with this input (native controller shortcuts).
    public var chord: [VirtualControllerElement]?
    /// Press again to release, for PC-style aim toggles.
    public var toggle: Bool?
    /// A different action while another controller element is active, such as firing
    /// with RT in bow aim mode while ordinary attacks use B.
    public var alternateWhile: VirtualControllerElement?
    public var alternateElement: VirtualControllerElement?
    /// Menu confirm/back can differ from the gameplay action on the same key.
    public var menuElement: VirtualControllerElement?
    /// Release latched aim/other modes before actions such as switching a character.
    public var releaseToggles: [VirtualControllerElement]?

    public init(keyCode: Int, element: VirtualControllerElement,
                chord: [VirtualControllerElement]? = nil, toggle: Bool? = nil,
                alternateWhile: VirtualControllerElement? = nil,
                alternateElement: VirtualControllerElement? = nil,
                menuElement: VirtualControllerElement? = nil,
                releaseToggles: [VirtualControllerElement]? = nil) {
        self.keyCode = keyCode
        self.element = element
        self.chord = chord
        self.toggle = toggle
        self.alternateWhile = alternateWhile
        self.alternateElement = alternateElement
        self.menuElement = menuElement
        self.releaseToggles = releaseToggles
    }
}

/// The elements of a standard extended gamepad.
public enum VirtualControllerElement: String, Codable, Sendable, CaseIterable {
    case buttonA, buttonB, buttonX, buttonY
    case leftShoulder, rightShoulder, leftTrigger, rightTrigger
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case leftThumbstickButton, rightThumbstickButton
    case buttonMenu, buttonOptions
    case leftStickUp, leftStickDown, leftStickLeft, leftStickRight
}

/// One keymap file. Upstream's name for this type is `KeymappingData`.
public struct KeymappingData: Codable, Sendable, Equatable {
    /// Explicit pointer profiles drive touches directly at the cursor without fixed HUD
    /// bindings. Native-only profiles cannot drive a touchscreen game.
    public var hasTouchControls: Bool {
        mulgControlProfile?.interactionStyle == .pointer
            || !buttonModels.isEmpty || !draggableButtonModels.isEmpty || !joystickModel.isEmpty
            || !mouseAreaModel.isEmpty || (mulgLayers ?? []).contains {
                !$0.buttonModels.isEmpty || !$0.draggableButtonModels.isEmpty
                    || !$0.joystickModel.isEmpty || !$0.mouseAreaModel.isEmpty
            }
    }
    public var buttonModels: [ButtonElement] = []
    public var draggableButtonModels: [ButtonElement] = []
    public var joystickModel: [JoystickElement] = []
    public var mouseAreaModel: [MouseAreaElement] = []
    public var bundleIdentifier: String
    public var version = "2.0.0"
    /// Fork addition: bindings for the virtual controller (§14.1).
    public var mulgControllerBindings: [ControllerBinding]?
    /// Fork addition: extra sets of bindings used while a key is held (§14.5). Upstream ignores
    /// the key, so keymaps with layers still open there (without the layers).
    public var mulgLayers: [KeymapLayer]?
    /// Optional game/context policy and group anchors. Touch bindings remain authoritative.
    public var mulgControlProfile: ControlMapProfile?
    /// Fork addition: width ÷ height of the game screen the keymap was made on. Lets a keymap
    /// made on the iPad screen (4:3) follow the game to a 16:9 4K or 5K window. Nil in keymaps
    /// from before it existed: those are used as they are.
    public var mulgAspectRatio: Double?
    /// Keep a coordinate-based preset at its calibrated shape while allowing window resizing.
    public var mulgLockAspectRatio: Bool?
    /// Optional, user-confirmed visual references. Older/imported maps need no conversion.
    public var mulgHUDAnchors: [ControlHUDAnchor]?

    enum CodingKeys: String, CodingKey {
        case buttonModels, draggableButtonModels, joystickModel, mouseAreaModel, bundleIdentifier, version
        case mulgControllerBindings, mulgLayers, mulgControlProfile, mulgAspectRatio, mulgLockAspectRatio, mulgHUDAnchors
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        buttonModels = try c.decode([ButtonElement].self, forKey: .buttonModels)
        draggableButtonModels = try c.decode([ButtonElement].self, forKey: .draggableButtonModels)
        joystickModel = try c.decode([JoystickElement].self, forKey: .joystickModel)
        mouseAreaModel = try c.decode([MouseAreaElement].self, forKey: .mouseAreaModel)
        bundleIdentifier = try c.decode(String.self, forKey: .bundleIdentifier)
        version = try c.decode(String.self, forKey: .version)
        mulgControllerBindings = try c.decodeIfPresent([ControllerBinding].self, forKey: .mulgControllerBindings)
        mulgLayers = try c.decodeIfPresent([KeymapLayer].self, forKey: .mulgLayers)
        mulgControlProfile = try c.decodeIfPresent(ControlMapProfile.self, forKey: .mulgControlProfile)
        mulgAspectRatio = try c.decodeIfPresent(Double.self, forKey: .mulgAspectRatio)
        mulgLockAspectRatio = try c.decodeIfPresent(Bool.self, forKey: .mulgLockAspectRatio)
        // A damaged/newer optional reference must never prevent the touch map loading.
        let anchors = try? c.decodeIfPresent([ControlHUDAnchor].self, forKey: .mulgHUDAnchors)
        mulgHUDAnchors = anchors.map { Array($0.filter(\.isValid).prefix(ControlHUDAnchor.maximumCount)) }
    }

    public init(bundleIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
    }

    /// Upstream refuses keymaps from a newer major format; so does the fork.
    public static let supportedVersionPrefix = "2.0."

    public var isSupportedVersion: Bool {
        version.hasPrefix(Self.supportedVersionPrefix)
    }
}

/// `.config.plist` in a game's keymap folder: which keymap is the default and the order.
public struct KeymapConfig: Codable, Sendable, Equatable {
    public var defaultKm: URL
    public var keymapOrder: [URL]

    public init(defaultKm: URL, keymapOrder: [URL]) {
        self.defaultKm = defaultKm
        self.keymapOrder = keymapOrder
    }

    enum CodingKeys: String, CodingKey { case defaultKm, keymapOrder }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(defaultKm: try c.decode(URL.self, forKey: .defaultKm),
                  keymapOrder: try c.decodeIfPresent([URL].self, forKey: .keymapOrder) ?? [])
    }
}

extension KeyModelTransform {
    /// All control types and layers use the same reference-canvas transform in both axes.
    public func fitted(from: Double, to: Double) -> KeyModelTransform {
        measuredHUDTransform(at: to)
            ?? KeymapCanvas(referenceAspectRatio: from, viewportAspectRatio: to)?.fitted(self) ?? self
    }
}
extension KeymapLayer {
    func fitted(from: Double, to: Double) -> KeymapLayer {
        var layer = self
        layer.buttonModels = buttonModels.map { var e = $0; e.transform = e.transform.fitted(from: from, to: to); return e }
        layer.draggableButtonModels = draggableButtonModels.map { var e = $0; e.transform = e.transform.fitted(from: from, to: to); return e }
        layer.joystickModel = joystickModel.map {
            var e = $0
            var transform = e.calibratedTransform(forAspect: to) ?? e.transform.fitted(from: from, to: to)
            transform.hudSamples = e.transform.hudSamples
            transform.hudBaselines = e.transform.hudBaselines
            e.transform = transform
            return e
        }
        layer.mouseAreaModel = mouseAreaModel.map { var e = $0; e.transform = e.transform.fitted(from: from, to: to); return e }
        return layer
    }
}

extension KeymappingData {
    /// The keymap placed for a game screen of `width` × `height` points, marked with that
    /// aspect. Same aspect (1080p, 4K and 5K are all 16:9) needs nothing: positions are
    /// fractions of the screen, so they scale with the resolution by themselves. Only a
    /// change of aspect moves elements, including tall windows; a keymap with no
    /// recorded aspect is taken as made for this screen.
    public func fitted(toWidth width: CGFloat, height: CGFloat) -> KeymappingData {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return self }
        let to = Double(width / height)
        var keymap = self
        keymap.mulgAspectRatio = to
        guard let from = mulgAspectRatio, from.isFinite, from > 0, to.isFinite, to > 0 else { return keymap }
        var base = KeymapLayer(name: "", holdKeyCode: 0, holdKeyName: "")
        base.buttonModels = buttonModels
        base.draggableButtonModels = draggableButtonModels
        base.joystickModel = joystickModel
        base.mouseAreaModel = mouseAreaModel
        base = base.fitted(from: from, to: to)
        keymap.buttonModels = base.buttonModels
        keymap.draggableButtonModels = base.draggableButtonModels
        keymap.joystickModel = base.joystickModel
        keymap.mouseAreaModel = base.mouseAreaModel
        keymap.mulgLayers = mulgLayers?.map { $0.fitted(from: from, to: to) }
        return keymap
    }
}
