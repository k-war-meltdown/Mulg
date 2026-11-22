import CoreGraphics
import Foundation
import MulgContracts
import MulgEngine
import MulgKeymaps
import os

/// One session of the control mapper: the draft being drawn, what the player is in the middle of
/// (choosing a control, naming a profile, answering a question) and the profiles. The UIKit overlay
/// only draws this and forwards clicks and key presses, so every rule here is tested without a screen.
///
/// The draft is a `KeymapEditorModel` (the editing rules every editor shares). Nothing reaches a
/// profile file until the player saves; switching or creating a profile first asks about unsaved changes.
@MainActor
public final class MapperSession {
    /// What the player is asked or asked to type; nothing while they are just drawing.
    public enum Prompt: Equatable {
        case none
        /// The control picker, opened by a click at this place (fractions of the canvas).
        case picker(CGPoint)
        case naming(NameKind)
        /// Close without saving, though there are unsaved changes.
        case confirmDiscard
        /// Leave this profile, though there are unsaved changes.
        case confirmLeave(Leave)
    }

    public enum NameKind: Equatable {
        case blankProfile
        case copyOfDraft
    }

    public enum Leave: Equatable {
        case profile(String)
        case newBlank(name: String)
    }

    public struct Message: Equatable {
        public let text: String
        public let isError: Bool
        /// Distinguishes one showing of a message from the next, so a repeated error is shown again.
        public let id: Int
        private static let counter = OSAllocatedUnfairLock(initialState: 0)

        public init(text: String, isError: Bool) {
            self.text = text
            self.isError = isError
            id = Self.counter.withLock { value in
                value += 1
                return value
            }
        }

        public static func == (lhs: Message, rhs: Message) -> Bool {
            lhs.text == rhs.text && lhs.isError == rhs.isError
        }
    }

    /// What the panel next to the selected control shows.
    public struct Inspector: Equatable {
        public struct ModeToggle: Equatable {
            public let title: String
            public let isOn: Bool
            public let help: String
        }
        public let id: Int
        public let tool: MapperTool
        public let title: String
        /// What the control is bound to, in words; "Press a key…" while it has nothing yet.
        public let binding: String
        public let isAwaitingKey: Bool
        public let detail: String
        public let modeToggle: ModeToggle?
        /// A button can't be bound to the left mouse button by clicking it (the click selects it).
        public let offersLeftClick: Bool
        /// A joystick's four directions with their labels, in up, left, down, right order.
        public let directions: [(part: KeymapEditorModel.Part, label: String)]
        public let focusedPart: KeymapEditorModel.Part?
        public let mouseAim: Bool?

        public static func == (lhs: Inspector, rhs: Inspector) -> Bool {
            lhs.id == rhs.id && lhs.tool == rhs.tool && lhs.title == rhs.title && lhs.binding == rhs.binding
                && lhs.isAwaitingKey == rhs.isAwaitingKey && lhs.detail == rhs.detail && lhs.modeToggle == rhs.modeToggle
                && lhs.offersLeftClick == rhs.offersLeftClick && lhs.focusedPart == rhs.focusedPart
                && lhs.mouseAim == rhs.mouseAim
                && lhs.directions.map(\.part) == rhs.directions.map(\.part)
                && lhs.directions.map(\.label) == rhs.directions.map(\.label)
        }
    }

    private struct Snapshot {
        let model: KeymapEditorModel
        let unbound: Set<Int>
    }

    public private(set) var model: KeymapEditorModel
    public private(set) var profile: String
    public private(set) var profiles: [ControlProfile] = []
    public private(set) var prompt: Prompt = .none
    public private(set) var message: Message?
    /// Controls placed but not yet bound to anything. A skill button with no key is thrown away when
    /// the player clicks away from it, since a control that does nothing only gets in the way.
    public private(set) var unbound: Set<Int> = []
    /// Bumped on every change, so the overlay redraws only when something changed.
    public private(set) var revision = 0
    /// True while the change being announced is a drag of the selected control, so the overlay can
    /// move it without redrawing everything.
    public private(set) var isMoving = false
    /// Called after every change.
    public var onChange: (() -> Void)?
    /// Fits a profile's keymap to the window's shape before it is edited (the overlay knows the shape).
    public var fit: (KeymappingData) -> KeymappingData

    private let host: ControlEditingHost
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var cachedDirty: Bool?
    private var dragStarted = false
    static let historyLimit = 60
    /// Keys that can't be bound (as the built-in editor): Control, Option, Command and Print Screen.
    static let unbindableKeyCodes: Set<Int> = [224, 226, 227, 228, 230, 231, 70]

    public init(keymap: KeymappingData, profile: String, host: ControlEditingHost,
                fit: @escaping (KeymappingData) -> KeymappingData = { $0 }) {
        self.fit = fit
        self.host = host
        self.profile = profile
        model = KeymapEditorModel(keymap: fit(keymap))
        model.select(nil)
        refreshProfiles()
    }

    // MARK: Reading the state

    public var elements: [KeymapEditorModel.Element] { model.visibleElements }
    public var selectedID: Int? { model.focused }
    public var selectedPart: KeymapEditorModel.Part? { model.focusedPart }
    public var canUndo: Bool { !undoStack.isEmpty }
    /// How many steps undo can take back.
    public var undoDepth: Int { undoStack.count }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var layerTitle: String { model.layerTitle }
    public var layerCount: Int { model.layers.count }
    public var currentLayer: Int { model.currentLayer }
    public var conflictingIDs: Set<Int> { model.conflictingElements }
    public var capturesText: Bool {
        if case .naming = prompt { return true }
        return false
    }
    /// A question the player must answer with its own buttons (not the picker).
    private var questionOpen: Bool {
        switch prompt {
        case .none, .picker: false
        case .naming, .confirmDiscard, .confirmLeave: true
        }
    }

    /// The draft as it would be saved: controls still waiting for a key are left out.
    public var finalModel: KeymapEditorModel {
        guard !unbound.isEmpty else { return model }
        var copy = model
        for id in unbound where copy.element(id) != nil {
            copy.select(id)
            copy.removeSelected()
        }
        copy.select(nil)
        return copy
    }

    /// Shows another profile's keymap (the controls module switched profile under the editor).
    public func replace(keymap: KeymappingData, profile: String) {
        adoptProfile(name: profile, keymap: keymap, text: nil)
    }

    /// Whether anything changed since the profile was opened. Cached between changes: working it out
    /// builds the whole keymap.
    public var hasUnsavedChanges: Bool {
        if let cachedDirty { return cachedDirty }
        let dirty = model.hasChanges
        cachedDirty = dirty
        return dirty
    }

    /// Keys used twice, in words; nil when each key does one thing.
    public var conflictSummary: String? {
        let conflicts = model.conflicts
        guard !conflicts.isEmpty else { return nil }
        return conflicts.prefix(2).map(\.description).joined(separator: "; ")
    }

    /// The text of the tip at the bottom of the screen, or nil when there is nothing to say.
    public var tip: String? {
        if let selected = inspector {
            return selected.isAwaitingKey
                ? "Press a key, a mouse button or a controller button. Click empty space to cancel."
                : nil
        }
        if elements.isEmpty {
            return "Click anywhere to add a control. Right-click drops a skill button."
        }
        return "Click a control to change its key · drag to move · click empty space to add · Esc to close"
    }

    public var inspector: Inspector? {
        guard let id = model.focused, let element = model.element(id), element.layer == model.currentLayer else { return nil }
        let isAwaiting = unbound.contains(id)
        let tool: MapperTool
        let title: String
        var binding = MapperKeyLabel.long(element.title)
        var detail = ""
        var toggle: Inspector.ModeToggle?
        var directions: [(part: KeymapEditorModel.Part, label: String)] = []
        var offersLeftClick = false
        var mouseAim: Bool?
        switch element.kind {
        case .button(let button):
            mouseAim = false
            tool = .skill; title = "Skill button"
            offersLeftClick = true
            detail = isAwaiting ? "Press a key, a mouse button or a controller button."
                : "Press another key to change it."
            toggle = Inspector.ModeToggle(title: "Hold / release", isOn: button.toggle == true,
                                          help: "One press holds the touch; the next press lets go.")
        case .joystick(let stick):
            let floating = stick.effectiveMode == .FLOATING
            tool = floating ? .floatingJoystick : .joystick
            title = floating ? "Floating joystick" : "Joystick"
            if stick.isAnalog {
                binding = MapperKeyLabel.long(stick.keyName)
                detail = "Driven by \(MapperKeyLabel.long(stick.keyName)). Press a key to go back to W A S D."
            } else {
                binding = [stick.upKeyCode, stick.leftKeyCode, stick.downKeyCode, stick.rightKeyCode]
                    .map { MapperKeyLabel.short(KeymapEditorModel.name(for: $0)) }.joined(separator: " ")
                detail = "Click a direction, then press a key to change it."
                directions = [(.up, "Up"), (.left, "Left"), (.down, "Down"), (.right, "Right")].map { part, name in
                    (part, name + ": " + MapperKeyLabel.short(element.title(of: part) ?? "?"))
                }
            }
            toggle = Inspector.ModeToggle(title: "Floating", isOn: floating,
                                          help: "Off: the game's stick stays in one place and Mulg presses on it. On: the game puts its stick wherever you press (Mulg presses here, then glides). Press J to switch.")
        case .cameraArea:
            tool = .camera; title = "Camera"
            binding = "Mouse"
            detail = "The mouse turns the camera. To drag while holding a key, add a Drag area instead."
        case .draggableButton(let drag):
            if drag.dragMotionBindingName == KeymapKeyNames.mouseMove { mouseAim = true }
            tool = .drag; title = "Drag area"
            offersLeftClick = true
            binding = isAwaiting ? "Press a key…" : MapperKeyLabel.long(drag.bindingName ?? "")
            detail = isAwaiting ? "Press the key to hold while you move the mouse."
                : "Hold \(MapperKeyLabel.short(drag.bindingName ?? "")) and move the mouse to drag."
        }
        if isAwaiting && tool != .drag { binding = "Press a key…" }
        if tool == .skill || tool == .drag || tool == .camera {
            detail += " Drag each edge to change width or height. The centre marks the touch point."
        }
        return Inspector(id: id, tool: tool, title: title, binding: binding, isAwaitingKey: isAwaiting, detail: detail,
                         modeToggle: toggle, offersLeftClick: offersLeftClick, directions: directions,
                         focusedPart: model.focusedPart, mouseAim: mouseAim)
    }

    // MARK: Placing and selecting

    /// A left click on empty canvas. While something is selected the click only deselects it (a control
    /// still waiting for a key is discarded); the next click opens the picker.
    public func clickEmpty(at point: CGPoint) {
        if prompt != .none {
            guard !questionOpen else { return }  // a question is answered with its buttons
            prompt = .none
            changed()
            return
        }
        if model.focused != nil {
            deselect()
            return
        }
        prompt = .picker(clamped(point))
        changed()
    }

    /// Places a control chosen in the picker.
    public func place(_ tool: MapperTool, at point: CGPoint) {
        prompt = .none
        discardWaitingControls(except: nil)
        pushHistory()
        let id = model.add(tool.newElement, at: clamped(point))
        if tool.startsUnbound { unbound.insert(id) }
        message = nil
        changed()
    }

    /// A right click on empty canvas drops a skill button there, ready for a key.
    public func rightClickEmpty(at point: CGPoint) {
        if questionOpen { return }
        place(.skill, at: point)
    }

    public func select(_ id: Int, part: KeymapEditorModel.Part? = nil) {
        guard !questionOpen else { return }
        prompt = .none
        if model.focused != id { discardWaitingControls(except: id) }
        model.select(id, part: part)
        changed()
    }

    public func deselect() {
        discardWaitingControls(except: nil)
        model.select(nil)
        changed()
    }

    // MARK: Moving, sizing, deleting

    /// Called when a drag of the selected control starts, so the whole drag is one undo step.
    public func beginMove() {
        guard model.focused != nil, !dragStarted else { return }
        pushHistory()
        dragStarted = true
    }

    public func endMove() {
        dragStarted = false
        changed()
    }

    /// Moves the selected control by a distance in fractions of the canvas.
    public func moveSelected(by delta: CGVector) {
        guard model.focused != nil else { return }
        if !dragStarted { beginMove() }
        model.moveSelected(by: delta)
        invalidateDirty()
        revision += 1
        isMoving = true
        onChange?()
        isMoving = false
    }

    public func resizeSelected(larger: Bool) {
        guard model.focused != nil else { return }
        pushHistory()
        model.resizeSelected(larger: larger)
        changed()
    }

    /// A resize drag: one undo step for the whole drag, like a move.
    public func setSelectedSize(_ size: CGFloat) {
        guard model.focused != nil else { return }
        if !dragStarted { beginMove() }
        model.setSelectedSize(size)
        invalidateDirty()
        revision += 1
        isMoving = true
        onChange?()
        isMoving = false
    }

    public func setSelectedBounds(center: CGPoint, width: CGFloat, height: CGFloat) {
        guard model.focused != nil else { return }
        if !dragStarted { beginMove() }
        model.setSelectedBounds(center: center, width: width, height: height)
        changed()
    }

    public func toggleSelectedMouseAim() {
        guard inspector?.mouseAim != nil else { return }
        pushHistory()
        model.toggleSelectedMouseAim()
        changed()
    }

    public func toggleSelectedMode() {
        guard let id = model.focused, let element = model.element(id) else { return }
        pushHistory()
        switch element.kind {
        case .joystick: model.toggleJoystickMode()
        case .button: model.toggleButtonHold()
        default: break
        }
        changed()
    }

    public func deleteSelected() {
        guard let id = model.focused else { return }
        pushHistory()
        model.removeSelected()
        unbound.remove(id)
        changed()
    }

    // MARK: Binding

    /// A key press (macOS virtual key code). Returns whether it was used; while editing, the game gets no keys.
    @discardableResult
    public func bindKey(virtualKeyCode: UInt16, control: Bool) -> Bool {
        if prompt != .none {
            if virtualKeyCode == 0x35 { cancelPrompt() }  // Escape closes the picker or a question
            return true
        }
        // Escape with nothing selected closes the mapper (asking first about unsaved changes). With a
        // control selected it is a key like any other: games bind Escape to their menu.
        if virtualKeyCode == 0x35, model.focused == nil {
            requestFinish(save: false)
            return true
        }
        guard let code = KeymapKeyNames.keymapCode(forVirtualKeyCode: virtualKeyCode),
              !Self.unbindableKeyCodes.contains(code), let name = KeymapKeyNames.name(forKeyCode: code) else { return false }
        // With nothing selected a key only matters in a layer (it becomes the layer's hold key).
        guard model.focused != nil || model.currentLayer > 0 else { return true }
        // A selected camera, or a keyboard joystick with no direction chosen, has no key to take; a stray
        // key press must not turn a camera into a drag area or leave empty steps in the undo list.
        if let kind = selectedKind {
            switch kind {
            case .camera: return true
            case .joystick(let stick) where !stick.isAnalog && model.focusedPart == nil: return true
            default: break
            }
        }
        let layerKey = model.focused == nil
        pushHistory()
        // A layer's hold key is matched by its plain name at runtime: "⌃W" as a hold key never switched the layer.
        let control = control && !layerKey
        let label = control ? "⌃" + name : name
        if control {
            model.assignKey(code: KeymapKeyNames.defaultCode, name: label)
        } else {
            model.assignKey(code: code, name: label)
        }
        afterBinding()
        if layerKey { message = Message(text: "Hold \(MapperKeyLabel.long(label)) to use this layer", isError: false) }
        return true
    }

    private enum SelectedKind {
        case camera
        case joystick(JoystickElement)
        case other
    }

    private var selectedKind: SelectedKind? {
        guard let id = model.focused, let element = model.element(id) else { return nil }
        switch element.kind {
        case .cameraArea: return .camera
        case .joystick(let stick): return .joystick(stick)
        default: return .other
        }
    }

    /// Whether a mouse button pressed now would bind the selected control: a skill button or drag area,
    /// or one direction of a joystick. A joystick as a whole or a camera has nothing to bind a button to.
    private var selectionTakesMouseButton: Bool {
        guard let kind = selectedKind else { return false }
        switch kind {
        case .camera: return false
        case .joystick: return model.focusedPart != nil && model.focusedPart != .grabKey
        case .other: return true
        }
    }

    /// A mouse button pressed over the canvas, other than the left one (0 left, 1 right, 2 middle, then
    /// extras), with the pointer's place as fractions of the canvas. It binds the selected control when that
    /// takes a mouse button and is waiting for one (just placed, or a joystick direction picked), or when the
    /// pointer is on it. Otherwise a right click drops a skill button at the pointer, so selecting a control
    /// to resize it never costs it its key. Returns whether the press was used.
    @discardableResult
    public func mouseButton(_ button: Int, pointerAt point: CGPoint, overSelection: Bool = false) -> Bool {
        if questionOpen { return true }
        let waiting = model.focused.map(unbound.contains) ?? false
        let directionPicked = model.focusedPart != nil && model.focusedPart != .grabKey
        if selectionTakesMouseButton, waiting || directionPicked || overSelection { return bindMouseButton(button) }
        if button == 1 {
            rightClickEmpty(at: point)
            return true
        }
        return prompt != .none
    }

    /// A mouse button other than the left one (0 left, 1 right, 2 middle, then extras).
    @discardableResult
    public func bindMouseButton(_ button: Int) -> Bool {
        if prompt != .none { return true }
        guard model.focused != nil, selectionTakesMouseButton else { return false }
        pushHistory()
        let code = KeymapKeyNames.code(forMouseButton: button) ?? KeymapKeyNames.defaultCode
        model.assignMouseButton(code: code, name: KeymapKeyNames.name(forMouseButton: button))
        afterBinding()
        return true
    }

    /// The left mouse button, which can't be pressed to bind it (a click selects).
    public func bindLeftClick() {
        guard model.focused != nil, selectionTakesMouseButton else { return }
        pushHistory()
        model.assignMouseButton(code: KeymapKeyNames.leftMouseCode, name: KeymapKeyNames.leftMouseButton)
        afterBinding()
    }

    /// A controller button or stick ("Button A", "Left Thumbstick").
    public func bindController(_ name: String) {
        guard prompt == .none, model.focused != nil else { return }
        pushHistory()
        model.assignControllerElement(name)
        afterBinding()
    }

    /// After a binding: a bound control is let go, so the next key press doesn't change it by accident.
    /// A joystick stays selected, for the player to go on with its other directions.
    private func afterBinding() {
        if let id = model.focused {
            unbound.remove(id)
            if let element = model.element(id), case .joystick = element.kind {
                model.select(id, part: nil)
            } else {
                model.select(nil)
            }
        }
        message = nil
        changed()
    }

    // MARK: Layers

    public func showLayer(offset: Int) {
        discardWaitingControls(except: nil)
        prompt = .none
        model.showLayer(offset: offset)
        changed()
    }

    public func addLayer() {
        discardWaitingControls(except: nil)
        prompt = .none
        pushHistory()
        model.addLayer()
        changed()
    }

    // MARK: Undo

    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(Snapshot(model: model, unbound: unbound))
        restore(previous)
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(Snapshot(model: model, unbound: unbound))
        restore(next)
    }

    private func restore(_ snapshot: Snapshot) {
        model = snapshot.model
        unbound = snapshot.unbound
        prompt = .none
        changed()
    }

    /// The window changed shape: positions are refitted, which is not an edit, so earlier undo steps (in the
    /// old shape) are dropped.
    public func reflow(toAspect aspect: Double) {
        model.reflow(toAspect: aspect)
        undoStack.removeAll()
        redoStack.removeAll()
        changed()
    }

    // MARK: Profiles

    public func refreshProfiles() {
        profiles = host.profiles()
    }

    /// Switches to a profile, asking first when there are unsaved changes.
    public func requestProfile(_ name: String) {
        guard name != profile else { return }
        discardWaitingControls(except: nil)
        if hasUnsavedChanges {
            prompt = .confirmLeave(.profile(name))
            changed()
        } else {
            leave(.profile(name), saving: nil)
        }
    }

    public func requestNewBlankProfile() {
        discardWaitingControls(except: nil)
        prompt = .naming(.blankProfile)
        message = nil
        changed()
    }

    /// Save this draft as a new profile, leaving the profile on disk as it is.
    public func requestCopyAsNewProfile() {
        discardWaitingControls(except: nil)
        prompt = .naming(.copyOfDraft)
        message = nil
        changed()
    }

    /// The name suggested when naming a profile.
    public var suggestedName: String {
        switch prompt {
        case .naming(.copyOfDraft): "\(profile) copy"
        default: "My controls"
        }
    }

    /// The player's answer to a naming prompt.
    public func submitName(_ text: String) {
        guard case .naming(let kind) = prompt else { return }
        guard let name = KeymapStore.sanitizedProfileName(text) else {
            message = Message(text: "Type a name for the profile.", isError: true)
            changed()
            return
        }
        switch kind {
        case .copyOfDraft:
            prompt = .none
            let result = host.createProfile(name, model.keymap(), nil)
            adopt(result, success: "Saved as “%@”")
        case .blankProfile:
            if hasUnsavedChanges {
                prompt = .confirmLeave(.newBlank(name: name))
                changed()
            } else {
                prompt = .none
                leave(.newBlank(name: name), saving: nil)
            }
        }
    }

    /// The player's answer when leaving a profile with unsaved changes: save them first, or drop them.
    public func confirmLeave(save: Bool) {
        guard case .confirmLeave(let leaveAction) = prompt else { return }
        prompt = .none
        leave(leaveAction, saving: save ? model.keymap() : nil)
    }

    private func leave(_ action: Leave, saving draft: KeymappingData?) {
        switch action {
        case .profile(let name):
            switch host.switchProfile(name, draft) {
            case .success(let keymap):
                adoptProfile(name: name, keymap: keymap, text: "Profile: “\(name)”")
            case .failure(let error):
                fail(error)
            }
        case .newBlank(let name):
            adopt(host.createProfile(name, nil, draft), success: "New profile “%@”")
        }
    }

    private func adopt(_ result: Result<(name: String, keymap: KeymappingData), ControlProfileError>, success: String) {
        switch result {
        case .success(let created):
            adoptProfile(name: created.name, keymap: created.keymap, text: success.replacingOccurrences(of: "%@", with: created.name))
        case .failure(let error):
            fail(error)
        }
    }

    private func adoptProfile(name: String, keymap: KeymappingData, text: String?) {
        profile = name
        model = KeymapEditorModel(keymap: fit(keymap))
        model.select(nil)
        unbound = []
        undoStack.removeAll()
        redoStack.removeAll()
        message = text.map { Message(text: $0, isError: false) }
        refreshProfiles()
        changed()
    }

    private func fail(_ error: ControlProfileError) {
        message = Message(text: error.message, isError: true)
        changed()
    }

    // MARK: Questions and finishing

    public func cancelPrompt() {
        guard prompt != .none else { return }
        prompt = .none
        changed()
    }

    /// Save (`true`) or Cancel (`false`). Cancel with unsaved changes asks first.
    public func requestFinish(save: Bool) {
        if !save, hasUnsavedChanges {
            prompt = .confirmDiscard
            changed()
            return
        }
        finish(save: save)
    }

    public func confirmDiscard() {
        guard prompt == .confirmDiscard else { return }
        prompt = .none
        finish(save: false)
    }

    private func finish(save: Bool) {
        if save { discardWaitingControls(except: nil) }
        host.finish(save)
    }

    // MARK: Internals

    private func pushHistory() {
        undoStack.append(Snapshot(model: model, unbound: unbound))
        if undoStack.count > Self.historyLimit { undoStack.removeFirst(undoStack.count - Self.historyLimit) }
        redoStack.removeAll()
        dragStarted = false
    }

    /// Controls still waiting for their first key, other than `keep`, are removed.
    private func discardWaitingControls(except keep: Int?) {
        let waiting = unbound.filter { $0 != keep }
        guard !waiting.isEmpty else { return }
        // If the only thing done since the placement is the placement itself, undo has nothing to undo.
        if let last = undoStack.last, last.model.elements.count == model.elements.count - waiting.count,
           last.unbound.isDisjoint(with: waiting) {
            undoStack.removeLast()
        }
        let selected = model.focused
        for id in waiting {
            model.select(id)
            model.removeSelected()
            unbound.remove(id)
        }
        if let selected, !waiting.contains(selected) { model.select(selected) }
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }

    private func invalidateDirty() { cachedDirty = nil }

    private func changed() {
        invalidateDirty()
        revision += 1
        onChange?()
    }
}
