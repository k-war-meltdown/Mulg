import CoreGraphics
import Foundation

/// What the in-game keymap editor edits, without any views (upstream `EditorController` and
/// the element controllers in Editor/Controllers). Kept apart from UIKit so every editing
/// rule is tested.
///
/// Rules kept from upstream:
/// - a button takes whatever is pressed next: a key, a mouse button or a controller button;
/// - a joystick shows four direction keys; pressing a key while one is selected sets it.
///   A thumbstick name makes it an analog stick, a mouse button makes it mouse-driven, and a
///   key on the joystick itself turns it back into a keyboard joystick;
/// - a draggable button has a move source (mouse or thumbstick) and a key that grabs it;
/// - a camera area takes a thumbstick or the mouse; gameplay keys never convert it into a
///   grabbed drag. Draggable controls are added explicitly for aimed skills;
/// - sizes change by 10 % a step.
///
/// Changes from upstream:
/// - positions are clamped to the screen while dragging, instead of the drag being ignored
///   once the finger passed the edge (which left elements stuck just inside it);
/// - sizes stay between 2 and 60 % of the screen, so an element can't vanish or cover it;
/// - saving keeps the parts of the keymap the editor does not show (controller bindings,
///   the format version), which upstream threw away on every save.
public struct KeymapEditorModel: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case button(ButtonElement)
        case draggableButton(ButtonElement)
        case joystick(JoystickElement)
        case cameraArea(MouseAreaElement)
    }

    /// A joystick's direction keys, in upstream's order (up, down, left, right), or the key
    /// that grabs a draggable button.
    public enum Part: Int, Sendable, Equatable, CaseIterable {
        case up, down, left, right
        /// The draggable button's own key.
        case grabKey
    }

    public struct Element: Sendable, Equatable, Identifiable {
        public let id: Int
        public var kind: Kind
        /// 0 for the base keymap, else the layer number (from 1, in keymap order).
        public var layer: Int = 0

        public var transform: KeyModelTransform {
            get {
                switch kind {
                case .button(let element), .draggableButton(let element): element.transform
                case .joystick(let element): element.transform
                case .cameraArea(let element): element.transform
                }
            }
            set {
                switch kind {
                case .button(var element):
                    element.transform = newValue
                    kind = .button(element)
                case .draggableButton(var element):
                    element.transform = newValue
                    kind = .draggableButton(element)
                case .joystick(var element):
                    if element.transform != newValue {
                        element.calibration = nil
                        element.calibrations = nil
                    }
                    element.transform = newValue
                    kind = .joystick(element)
                case .cameraArea(var element):
                    element.transform = newValue
                    kind = .cameraArea(element)
                }
            }
        }

        /// The main label shown on the element.
        public var title: String {
            switch kind {
            case .button(let element): element.keyName
            case .draggableButton(let element): element.dragMotionBindingName
            case .joystick(let element): element.isAnalog ? element.keyName : ""
            case .cameraArea(let element): element.keyName
            }
        }

        /// The inputs this element listens to, as keymaps name them (for conflict marking).
        public var inputs: [String] {
            switch kind {
            case .button(let element): element.bindingName.map { [$0] } ?? []
            case .draggableButton(let element): element.bindingName.map { [$0] } ?? []
            case .joystick(let element) where element.isAnalog: [element.keyName]
            case .joystick(let element):
                [element.upKeyCode, element.downKeyCode, element.leftKeyCode, element.rightKeyCode].map(KeymapEditorModel.name(for:))
            case .cameraArea(let element): [element.keyName]
            }
        }

        /// The label of a part (a joystick direction or a draggable button's key).
        public func title(of part: Part) -> String? {
            switch (kind, part) {
            case (.joystick(let element), .up) where !element.isAnalog: KeymapEditorModel.name(for: element.upKeyCode)
            case (.joystick(let element), .down) where !element.isAnalog: KeymapEditorModel.name(for: element.downKeyCode)
            case (.joystick(let element), .left) where !element.isAnalog: KeymapEditorModel.name(for: element.leftKeyCode)
            case (.joystick(let element), .right) where !element.isAnalog: KeymapEditorModel.name(for: element.rightKeyCode)
            case (.draggableButton(let element), .grabKey): element.bindingName
            default: nil
            }
        }
    }

    /// Something the player can place from the add menu.
    public enum NewElement: String, Sendable, CaseIterable {
        case button, joystick, floatingJoystick, cameraArea, draggableButton

        public var title: String {
            switch self {
            case .button: "Button"
            case .joystick: "Joystick"
            case .floatingJoystick: "Floating joystick"
            case .cameraArea: "Camera"
            case .draggableButton: "Draggable"
            }
        }

        public var symbol: String {
            switch self {
            case .button: "circle.circle"
            case .joystick: "dpad"
            case .floatingJoystick: "dpad.fill"
            case .cameraArea: "computermouse"
            case .draggableButton: "hand.draw"
            }
        }
    }

    public static let sizeRange: ClosedRange<CGFloat> = 2...60

    /// Every element of every layer; the editor shows `visibleElements`.
    public private(set) var elements: [Element] = []
    /// The layers' names and hold keys; their elements are in `elements`.
    public private(set) var layers: [KeymapLayer] = []
    /// The layer being edited: 0 is the base keymap.
    public private(set) var currentLayer = 0
    public private(set) var focused: Int?
    public private(set) var focusedPart: Part?
    /// The keymap as it was opened, for the parts the editor does not show.
    private var original: KeymappingData
    private var invalidatedHUDLayers: Set<Int> = []
    private var nextID = 0

    public init(keymap: KeymappingData) {
        original = keymap
        // Upstream's order: draggable buttons, joysticks, camera areas, buttons.
        for element in keymap.draggableButtonModels { append(.draggableButton(element)) }
        for element in keymap.joystickModel { append(.joystick(element)) }
        for element in keymap.mouseAreaModel { append(.cameraArea(element)) }
        for element in keymap.buttonModels { append(.button(element)) }
        for (index, layer) in (keymap.mulgLayers ?? []).enumerated() {
            currentLayer = index + 1
            for element in layer.draggableButtonModels { append(.draggableButton(element)) }
            for element in layer.joystickModel { append(.joystick(element)) }
            for element in layer.mouseAreaModel { append(.cameraArea(element)) }
            for element in layer.buttonModels { append(.button(element)) }
            var header = layer
            header.buttonModels = []
            header.draggableButtonModels = []
            header.joystickModel = []
            header.mouseAreaModel = []
            layers.append(header)
        }
        currentLayer = 0
        focused = nil
        focusedPart = nil
    }

    /// The keymap to save.
    public func keymap() -> KeymappingData {
        var keymap = original
        keymap.mulgHUDAnchors = original.mulgHUDAnchors?.filter { !invalidatedHUDLayers.contains($0.address.layer) }
        keymap.buttonModels = []
        keymap.draggableButtonModels = []
        keymap.joystickModel = []
        keymap.mouseAreaModel = []
        var saved = layers
        for element in elements {
            if element.layer == 0 {
                switch element.kind {
                case .button(let button): keymap.buttonModels.append(button)
                case .draggableButton(let button): keymap.draggableButtonModels.append(button)
                case .joystick(let joystick): keymap.joystickModel.append(joystick)
                case .cameraArea(let area): keymap.mouseAreaModel.append(area)
                }
            } else if saved.indices.contains(element.layer - 1) {
                switch element.kind {
                case .button(let button): saved[element.layer - 1].buttonModels.append(button)
                case .draggableButton(let button): saved[element.layer - 1].draggableButtonModels.append(button)
                case .joystick(let joystick): saved[element.layer - 1].joystickModel.append(joystick)
                case .cameraArea(let area): saved[element.layer - 1].mouseAreaModel.append(area)
                }
            }
        }
        // A new layer that never got a key or an element is not saved.
        saved.removeAll { !$0.hasHoldKey && $0.isEmpty }
        keymap.mulgLayers = saved.isEmpty && original.mulgLayers == nil ? nil : saved
        return keymap.withLearnedControlLayouts()
    }

    public var hasChanges: Bool { keymap() != original }

    /// The same address used by the runtime binding graph, independent of editor IDs.
    public var selectedHUDAddress: ControlBindingAddress? {
        guard let focused, let selected = element(focused) else { return nil }
        func kind(_ element: Element) -> ControlBindingKind {
            switch element.kind {
            case .button: .button
            case .draggableButton: .draggable
            case .joystick(let stick): stick.isAnalog ? .analogJoystick : .digitalJoystick
            case .cameraArea: .camera
            }
        }
        let selectedKind = kind(selected)
        guard selectedKind != .camera else { return nil }
        // Both analog and digital sticks share the joystickModel array.
        let siblings = elements.filter { element in
            guard element.layer == selected.layer else { return false }
            if case .joystick = selected.kind, case .joystick = element.kind { return true }
            return kind(element) == selectedKind
        }
        guard let index = siblings.firstIndex(where: { $0.id == focused }) else { return nil }
        return ControlBindingAddress(layer: selected.layer, kind: selectedKind, index: index)
    }

    public func element(_ id: Int) -> Element? {
        elements.first { $0.id == id }
    }

    // MARK: Adding, selecting, removing

    /// Adds an element centred on `point` (fractions of the screen) and selects it.
    @discardableResult
    public mutating func add(_ new: NewElement, at point: CGPoint) -> Int {
        let x = Self.clamp(point.x)
        let y = Self.clamp(point.y)
        switch new {
        case .button:
            append(.button(ButtonElement(keyCode: KeymapKeyNames.leftMouseCode, keyName: KeymapKeyNames.leftMouseButton,
                                         transform: KeyModelTransform(size: 5, xCoord: x, yCoord: y))))
        case .joystick, .floatingJoystick:
            // Fixed: the game's stick sits here and the touch starts on it. Floating: the game puts
            // its stick wherever a touch starts, so this is only where Mulg touches down.
            append(.joystick(JoystickElement(upKeyCode: Self.keyW, rightKeyCode: Self.keyD, downKeyCode: Self.keyS,
                                             leftKeyCode: Self.keyA, keyName: "Keyboard",
                                             transform: KeyModelTransform(size: 20, xCoord: x, yCoord: y),
                                             mode: new == .floatingJoystick ? .FLOATING : .FIXED)))
        case .cameraArea:
            append(.cameraArea(MouseAreaElement(keyName: KeymapKeyNames.mouseMove,
                                                transform: KeyModelTransform(size: 25, xCoord: x, yCoord: y))))
        case .draggableButton:
            append(.draggableButton(ButtonElement(keyCode: KeymapKeyNames.leftMouseCode, keyName: KeymapKeyNames.mouseMove,
                                                  transform: KeyModelTransform(size: 15, xCoord: x, yCoord: y))))
        }
        return elements[elements.count - 1].id
    }

    public mutating func select(_ id: Int?, part: Part? = nil) {
        guard let id, let element = element(id), element.layer == currentLayer else {
            focused = nil
            focusedPart = nil
            return
        }
        focused = id
        focusedPart = part
    }

    public mutating func removeSelected() {
        guard let focused else { return }
        if let selected = element(focused) { invalidatedHUDLayers.insert(selected.layer) }
        elements.removeAll { $0.id == focused }
        self.focused = nil
        focusedPart = nil
    }

    // MARK: Layers (§14.5)

    /// The elements of the layer being edited.
    public var visibleElements: [Element] {
        elements.filter { $0.layer == currentLayer }
    }

    /// "Base keymap", or the layer's name and hold key.
    public var layerTitle: String {
        guard currentLayer > 0, layers.indices.contains(currentLayer - 1) else { return "Base keymap" }
        let layer = layers[currentLayer - 1]
        let key = layer.hasHoldKey ? "hold \(layer.holdKeyName)" : "press a key with nothing selected to choose its hold key"
        return "\(layer.name) (\(key))"
    }

    /// Shows the next or previous layer, the base keymap included.
    public mutating func showLayer(offset: Int) {
        let count = layers.count + 1
        currentLayer = ((currentLayer + offset) % count + count) % count
        focused = nil
        focusedPart = nil
    }

    /// Adds an empty layer and shows it. Its hold key is the next key pressed with nothing selected.
    public mutating func addLayer() {
        layers.append(KeymapLayer(name: "Layer \(layers.count + 1)", holdKeyCode: KeymapKeyNames.defaultCode, holdKeyName: ""))
        currentLayer = layers.count
        focused = nil
        focusedPart = nil
    }

    /// Elements of the shown layer that share an input with another element (or bind one input
    /// twice, like a joystick with the same key for two directions).
    public var conflictingElements: Set<Int> {
        var byInput: [String: [Int]] = [:]
        for element in visibleElements {
            for input in element.inputs {
                byInput[input, default: []].append(element.id)
            }
        }
        return Set(byInput.values.filter { $0.count > 1 }.flatMap { $0 })
    }

    /// Inputs bound twice in one layer, and layer keys that hide a binding.
    public var conflicts: [KeymapConflict] {
        KeymapConflicts.find(in: keymap())
    }

    /// With nothing selected in a layer, the key pressed becomes the layer's hold key.
    /// Control+key names can't hold a layer (the layer key is matched without modifiers).
    private mutating func setHoldKey(code: Int, name: String) {
        guard currentLayer > 0, layers.indices.contains(currentLayer - 1), code != KeymapKeyNames.defaultCode else { return }
        layers[currentLayer - 1].holdKeyCode = code
        layers[currentLayer - 1].holdKeyName = name
    }

    // MARK: Moving and sizing

    /// Fit both the clean map and draft from immutable samples. Viewport changes do not
    /// become edits, discard selection, clear joystick calibration or accumulate offsets.
    public mutating func reflow(toAspect aspect: Double) {
        guard aspect.isFinite, aspect > 0, let from = original.mulgAspectRatio,
              from.isFinite, from > 0, abs(log(aspect / from)) > 0.000001 else { return }
        for index in elements.indices {
            let transform = elements[index].transform.withAdaptiveHUDSamples(referenceAspect: from)
                .fitted(from: from, to: aspect)
            switch elements[index].kind {
            case .button(var element):
                element.transform = transform
                elements[index].kind = .button(element)
            case .draggableButton(var element):
                element.transform = transform
                elements[index].kind = .draggableButton(element)
            case .cameraArea(var element):
                element.transform = transform
                elements[index].kind = .cameraArea(element)
            case .joystick(var element):
                var fitted = element.calibratedTransform(forAspect: aspect) ?? transform
                fitted.hudSamples = transform.hudSamples
                fitted.hudBaselines = transform.hudBaselines
                element.transform = fitted
                elements[index].kind = .joystick(element)
            }
        }
        original = original.withAdaptiveLayouts().fitted(toWidth: CGFloat(aspect), height: 1)
    }

    private mutating func applyMeasuredTransform(_ transform: KeyModelTransform, at index: Int) {
        invalidatedHUDLayers.insert(elements[index].layer)
        if case .joystick(var element) = elements[index].kind,
           let aspect = original.mulgAspectRatio,
           var measurement = element.calibration ?? element.calibrations?.first(where: \.isValid) {
            // Adjust this measured shape without erasing the stick's measurements elsewhere.
            measurement.transform = transform
            measurement.transform.hudSamples = nil
            measurement.transform.hudBaselines = nil
            measurement.aspectRatio = aspect
            element.recordCalibration(measurement)
            element.transform = transform
            elements[index].kind = .joystick(element)
        } else { elements[index].transform = transform }
    }

    /// Moves the selected element by a distance in fractions of the screen.
    public mutating func moveSelected(by delta: CGVector) {
        guard let index = focusedIndex else { return }
        var transform = elements[index].transform
        transform.xCoord = Self.clamp(transform.xCoord + delta.dx)
        transform.yCoord = Self.clamp(transform.yCoord + delta.dy)
        if let aspect = original.mulgAspectRatio { transform.recordHUDSample(at: aspect) }
        applyMeasuredTransform(transform, at: index)
    }

    public mutating func resizeSelected(larger: Bool) {
        guard let index = focusedIndex else { return }
        var transform = elements[index].transform
        let factor: CGFloat = larger ? 1 / 0.9 : 0.9
        transform.size = min(max(transform.size * factor, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        if let aspect = original.mulgAspectRatio { transform.recordHUDSample(at: aspect) }
        applyMeasuredTransform(transform, at: index)
    }

    /// Sets the selected control's size (percent of the longer screen side), within `sizeRange`.
    public mutating func setSelectedSize(_ size: CGFloat) {
        guard let index = focusedIndex, size.isFinite else { return }
        var transform = elements[index].transform
        transform.size = min(max(size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        if let aspect = original.mulgAspectRatio { transform.recordHUDSample(at: aspect) }
        applyMeasuredTransform(transform, at: index)
    }

    /// Rectangular editor bounds. Independent edge resizing also moves the centre so the
    /// opposite edge stays fixed. Joysticks retain their circular travel geometry.
    public mutating func setSelectedBounds(center: CGPoint, width: CGFloat, height: CGFloat) {
        guard let index = focusedIndex, center.x.isFinite, center.y.isFinite,
              width.isFinite, height.isFinite, width > 0, height > 0 else { return }
        if case .joystick = elements[index].kind { return }
        var transform = elements[index].transform
        guard transform.size.isFinite, transform.size > 0 else { return }
        transform.xCoord = Self.clamp(center.x)
        transform.yCoord = Self.clamp(center.y)
        transform.widthScale = min(max(width / transform.size, 0.01), 100)
        transform.heightScale = min(max(height / transform.size, 0.01), 100)
        if let aspect = original.mulgAspectRatio { transform.recordHUDSample(at: aspect) }
        applyMeasuredTransform(transform, at: index)
    }

    /// Native mobile aiming sometimes belongs to the held attack/skill touch itself.
    /// Preserve the authored button when switching between a fixed press and mouse aim.
    public mutating func toggleSelectedMouseAim() {
        guard let index = focusedIndex else { return }
        switch elements[index].kind {
        case .button(var button):
            button.dragMotionSource = KeymapKeyNames.mouseMove
            elements[index].kind = .draggableButton(button)
        case .draggableButton(let button) where button.dragMotionBindingName == KeymapKeyNames.mouseMove:
            elements[index].kind = .button(button)
        default: break
        }
    }

    /// Switches the selected joystick between fixed and floating (it follows the first touch).
    public mutating func toggleJoystickMode() {
        guard let index = focusedIndex, case .joystick(var joystick) = elements[index].kind else { return }
        joystick.mode = joystick.effectiveMode == .FIXED ? .FLOATING : .FIXED
        elements[index].kind = .joystick(joystick)
    }

    /// Switches the selected button between hold (the touch lasts while the key is down) and
    /// toggle (one press holds it, the next lifts it). Accessibility, PLAN.md §13.2.
    public mutating func toggleButtonHold() {
        guard let index = focusedIndex, case .button(var button) = elements[index].kind else { return }
        button.toggle = (button.toggle ?? false) ? nil : true
        elements[index].kind = .button(button)
    }

    // MARK: Assigning inputs

    /// A key was pressed: `code` is its keymap code (HID usage), `name` its keymap name
    /// ("W", or "⌃W" with Control held, in which case the code is `defaultCode`).
    public mutating func assignKey(code: Int, name: String) {
        guard let index = focusedIndex else {
            setHoldKey(code: code, name: name)
            return
        }
        // Mouse-look is a motion binding. R or any other key must not replace it with a grab.
        if case .cameraArea = elements[index].kind { return }
        invalidatedHUDLayers.insert(elements[index].layer)
        switch elements[index].kind {
        case .button(var button):
            button.keyCode = code
            button.keyName = name
            elements[index].kind = .button(button)
        case .draggableButton(var button):
            button.dragMotionSource = button.dragMotionBindingName
            button.keyCode = code
            if code == KeymapKeyNames.defaultCode { button.keyName = name }
            elements[index].kind = .draggableButton(button)
            focusedPart = .grabKey
        case .joystick(var joystick):
            switch focusedPart {
            case .up?: joystick.upKeyCode = code
            case .down?: joystick.downKeyCode = code
            case .left?: joystick.leftKeyCode = code
            case .right?: joystick.rightKeyCode = code
            case .grabKey?, nil:
                // A key on the joystick itself: back to a keyboard joystick.
                joystick.keyName = "Keyboard"
            }
            elements[index].kind = .joystick(joystick)
        case .cameraArea:
            break
        }
    }

    /// A mouse button (`code` negative, name "LMB", "RMB", "MMB" or "MBtnN").
    public mutating func assignMouseButton(code: Int, name: String) {
        guard let index = focusedIndex else {
            setHoldKey(code: code, name: name)
            return
        }
        invalidatedHUDLayers.insert(elements[index].layer)
        switch elements[index].kind {
        case .button(var button):
            button.keyCode = code
            button.keyName = name
            elements[index].kind = .button(button)
        case .draggableButton(var button):
            if focusedPart == .grabKey {
                button.keyCode = code
            } else {
                button.dragMotionSource = KeymapKeyNames.mouseMove
            }
            elements[index].kind = .draggableButton(button)
        case .joystick(var joystick):
            if let part = focusedPart, part != .grabKey {
                assignJoystickPart(&joystick, part: part, code: code)
            } else {
                joystick.keyName = KeymapKeyNames.mouseMove
            }
            elements[index].kind = .joystick(joystick)
        case .cameraArea(var area):
            area.keyName = KeymapKeyNames.mouseMove
            elements[index].kind = .cameraArea(area)
        }
    }

    /// A controller element, by its Game Controller name ("Button A", "Left Thumbstick").
    public mutating func assignControllerElement(_ name: String) {
        guard let index = focusedIndex else { return }
        invalidatedHUDLayers.insert(elements[index].layer)
        let isStick = KeymapKeyNames.thumbstickNames.contains(name)
        switch elements[index].kind {
        case .button(var button):
            button.keyCode = KeymapKeyNames.defaultCode
            button.keyName = name
            elements[index].kind = .button(button)
        case .draggableButton(var button):
            if isStick {
                button.dragMotionSource = name
            } else {
                button.dragMotionSource = button.dragMotionBindingName
                button.keyCode = KeymapKeyNames.defaultCode
                button.keyName = name
            }
            elements[index].kind = .draggableButton(button)
        case .joystick(var joystick):
            if isStick {
                joystick.keyName = name
                elements[index].kind = .joystick(joystick)
                focusedPart = nil
            }
        case .cameraArea(var area):
            if isStick {
                area.keyName = name
                elements[index].kind = .cameraArea(area)
            }
        }
    }

    // MARK: Helpers

    private var focusedIndex: Int? {
        guard let focused else { return nil }
        return elements.firstIndex { $0.id == focused }
    }

    private mutating func append(_ kind: Kind) {
        elements.append(Element(id: nextID, kind: kind, layer: currentLayer))
        focused = nextID
        focusedPart = nil
        nextID += 1
    }

    private func assignJoystickPart(_ joystick: inout JoystickElement, part: Part, code: Int) {
        switch part {
        case .up: joystick.upKeyCode = code
        case .down: joystick.downKeyCode = code
        case .left: joystick.leftKeyCode = code
        case .right: joystick.rightKeyCode = code
        case .grabKey: break
        }
    }

    static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }

    public static func name(for code: Int) -> String {
        if let name = KeymapKeyNames.name(forKeyCode: code) {
            return name
        }
        switch code {
        case KeymapKeyNames.leftMouseCode: return KeymapKeyNames.leftMouseButton
        case KeymapKeyNames.rightMouseCode: return KeymapKeyNames.rightMouseButton
        case KeymapKeyNames.middleMouseCode: return KeymapKeyNames.middleMouseButton
        default: return "Btn"
        }
    }

    // HID usages for W, A, S, D, the default joystick keys.
    static let keyW = 26
    static let keyA = 4
    static let keyS = 22
    static let keyD = 7
}

/// Where the input router sends keys and mouse buttons while the editor is open (upstream's
/// Editor*EventAdapter classes).
@MainActor
public protocol KeymapEditorInput: AnyObject {
    /// A key press; returns false when the key can't be bound.
    func editorKey(code: UInt16, ctrlModified: Bool) -> Bool
    /// A mouse button other than the left one (0 left, 1 right, 2 middle, then extras).
    func editorMouseButton(_ button: Int) -> Bool
    /// True while the editor has a text field to type in (naming a profile): keys then go to the
    /// text field instead of being bound.
    var capturesText: Bool { get }
}

public extension KeymapEditorInput {
    var capturesText: Bool { false }
}
