import CoreGraphics
import Foundation
import MulgContracts
import MulgEngine
import MulgKeymaps
@testable import MulgMapper
import Testing

/// A stand-in for the controls module: records what the mapper asks of it.
@MainActor
final class FakeHost {
    var profiles = [ControlProfile(name: "Genshin", isActive: true, controlCount: 3),
                    ControlProfile(name: "Combat", isActive: false, controlCount: 5)]
    var stored: [String: KeymappingData] = [:]
    var finished: [Bool] = []
    var switched: [(name: String, saved: KeymappingData?)] = []
    var created: [(name: String, keymap: KeymappingData?, saved: KeymappingData?)] = []
    var failNext: String?

    var host: ControlEditingHost {
        ControlEditingHost(
            profiles: { [unowned self] in profiles },
            switchProfile: { [unowned self] name, saved in
                if let failNext { self.failNext = nil; return .failure(ControlProfileError(failNext)) }
                switched.append((name, saved))
                return .success(stored[name] ?? KeymappingData(bundleIdentifier: "g"))
            },
            createProfile: { [unowned self] name, keymap, saved in
                if let failNext { self.failNext = nil; return .failure(ControlProfileError(failNext)) }
                created.append((name, keymap, saved))
                let unique = profiles.contains { $0.name.lowercased() == name.lowercased() } ? name + " 2" : name
                return .success((unique, keymap ?? KeymappingData(bundleIdentifier: "g")))
            },
            finish: { [unowned self] save in finished.append(save) })
    }
}

@Suite("Mapper session") @MainActor
struct MapperSessionTests {
    let fake = FakeHost()

    private func map() -> KeymappingData {
        var map = KeymappingData(bundleIdentifier: "g")
        map.buttonModels = [ButtonElement(keyCode: 8, keyName: "E", transform: KeyModelTransform(size: 5, xCoord: 0.8, yCoord: 0.8))]
        map.joystickModel = [JoystickElement(upKeyCode: 26, rightKeyCode: 7, downKeyCode: 22, leftKeyCode: 4,
                                             transform: KeyModelTransform(size: 20, xCoord: 0.2, yCoord: 0.7))]
        return map
    }

    private func session(_ keymap: KeymappingData? = nil) -> MapperSession {
        MapperSession(keymap: keymap ?? map(), profile: "Genshin", host: fake.host)
    }

    private let point = CGPoint(x: 0.4, y: 0.5)

    @Test("Rectangular resizing persists both dimensions with one undo step per gesture")
    func rectangularResize() throws {
        let s = session()
        let id = try #require(s.elements.first(where: { if case .button = $0.kind { return true }; return false })?.id)
        s.select(id)
        let original = s.model.keymap()
        s.setSelectedBounds(center: CGPoint(x: 0.7, y: 0.8), width: 12, height: 5)
        s.setSelectedBounds(center: CGPoint(x: 0.6, y: 0.8), width: 18, height: 5)
        s.endMove()
        #expect(s.undoDepth == 1)
        let edited = s.model.keymap()
        let button = try #require(edited.buttonModels.first)
        #expect(button.transform.widthScale == 3.6 && button.transform.heightScale == 1)
        #expect(button.keyCode == original.buttonModels.first?.keyCode)
        let decoded = try PropertyListDecoder().decode(KeymappingData.self, from: PropertyListEncoder().encode(edited))
        #expect(decoded == edited)
        s.undo()
        #expect(s.model.keymap() == original)
        s.redo()
        #expect(s.model.keymap() == edited)
    }

    @Test("Mouse aiming can be enabled per button and undone without losing its binding or shape")
    func mouseAimButton() throws {
        let s = session()
        let id = try #require(s.elements.first(where: { if case .button = $0.kind { return true }; return false })?.id)
        s.select(id)
        let original = s.model.keymap()
        #expect(s.inspector?.mouseAim == false)
        s.toggleSelectedMouseAim()
        #expect(s.inspector?.mouseAim == true)
        let drag = try #require(s.model.keymap().draggableButtonModels.first)
        #expect(drag.keyCode == original.buttonModels.first?.keyCode)
        #expect(drag.transform == original.buttonModels.first?.transform)
        s.toggleSelectedMouseAim()
        #expect(s.inspector?.mouseAim == false)
        #expect(s.model.keymap().buttonModels.first?.keyCode == drag.keyCode)
        s.undo(); s.undo()
        #expect(s.model.keymap() == original)
    }

    // MARK: Placing

    @Test("A left click on empty space opens the picker; nothing is added until a control is chosen")
    func clickOpensPicker() {
        let s = session()
        s.clickEmpty(at: point)
        #expect(s.prompt == .picker(point))
        #expect(s.elements.count == 2)
        #expect(!s.hasUnsavedChanges)
    }

    @Test("Choosing a skill button places it selected and waiting for a key")
    func placeSkill() throws {
        let s = session()
        s.clickEmpty(at: point)
        s.place(.skill, at: point)
        #expect(s.prompt == .none)
        #expect(s.elements.count == 3)
        let inspector = try #require(s.inspector)
        #expect(inspector.tool == .skill && inspector.isAwaitingKey && inspector.binding == "Press a key…")
        #expect(s.hasUnsavedChanges)
    }

    @Test("A right click drops a skill button at the pointer")
    func rightClick() throws {
        let s = session()
        s.rightClickEmpty(at: point)
        let element = try #require(s.elements.last)
        #expect(abs(element.transform.xCoord - 0.4) < 1e-9 && abs(element.transform.yCoord - 0.5) < 1e-9)
        #expect(s.inspector?.isAwaitingKey == true)
    }

    @Test("The next key binds the new skill button, which is then let go")
    func bindNewSkill() throws {
        let s = session()
        s.rightClickEmpty(at: point)
        #expect(s.bindKey(virtualKeyCode: 0x0E, control: false))  // E
        #expect(s.selectedID == nil)                              // not rebound by the next key by accident
        let button = try #require(s.model.keymap().buttonModels.last)
        #expect(button.keyName == "E" && button.keyCode == 8)
        #expect(s.unbound.isEmpty)
        // A second key press with nothing selected changes nothing.
        let before = s.model.keymap()
        _ = s.bindKey(virtualKeyCode: 0x0C, control: false)
        #expect(s.model.keymap() == before)
    }

    @Test("A control left without a key is thrown away when the player clicks away")
    func unboundIsDiscarded() {
        let s = session()
        s.rightClickEmpty(at: point)
        #expect(s.elements.count == 3)
        s.clickEmpty(at: CGPoint(x: 0.1, y: 0.1))   // clicking away
        #expect(s.elements.count == 2)
        #expect(s.selectedID == nil)
        #expect(s.prompt == .none)                   // the picker waits for the next click
        #expect(!s.hasUnsavedChanges)
    }

    @Test("Clicking away from a selected control only deselects it; the next click opens the picker")
    func clickAwayFromBound() throws {
        let s = session()
        let id = try #require(s.elements.first { if case .button = $0.kind { true } else { false } }?.id)
        s.select(id)
        s.clickEmpty(at: point)
        #expect(s.selectedID == nil && s.prompt == .none)
        s.clickEmpty(at: point)
        #expect(s.prompt == .picker(point))
        s.clickEmpty(at: point)                 // a click while the picker is open closes it
        #expect(s.prompt == .none)
    }

    @Test("A joystick and a camera start bound; a drag area waits for its key")
    func toolsStartBound() throws {
        let s = session(KeymappingData(bundleIdentifier: "g"))
        s.place(.joystick, at: point)
        #expect(s.inspector?.isAwaitingKey == false)
        #expect(s.inspector?.binding == "W A S D")
        s.place(.camera, at: point)
        #expect(s.inspector?.tool == .camera)
        s.place(.drag, at: point)
        #expect(s.inspector?.isAwaitingKey == true)
        #expect(s.model.keymap().joystickModel.count == 1)
        // The camera and joystick stayed, the waiting drag area is not in the saved map yet.
        s.requestFinish(save: true)
        #expect(s.model.keymap().draggableButtonModels.isEmpty)
        #expect(s.model.keymap().mouseAreaModel.count == 1)
        #expect(fake.finished == [true])
    }

    // MARK: Rebinding

    @Test("Clicking an existing control and pressing a key rebinds it")
    func rebind() throws {
        let s = session()
        let id = try #require(s.elements.first { if case .button = $0.kind { true } else { false } }?.id)
        s.select(id)
        #expect(s.inspector?.isAwaitingKey == false)
        #expect(s.inspector?.binding == "E")
        _ = s.bindKey(virtualKeyCode: 0x0C, control: false)   // Q
        #expect(s.model.keymap().buttonModels.first?.keyName == "Q")
        #expect(s.selectedID == nil)
    }

    @Test("A joystick direction is rebound by clicking it, and the joystick stays selected")
    func joystickDirection() throws {
        let s = session()
        let stick = try #require(s.elements.first { if case .joystick = $0.kind { true } else { false } })
        s.select(stick.id, part: .up)
        _ = s.bindKey(virtualKeyCode: 0x7E, control: false)   // Up arrow
        let saved = try #require(s.model.keymap().joystickModel.first)
        #expect(saved.upKeyCode == 82 && saved.downKeyCode == 22)
        #expect(s.selectedID == stick.id && s.selectedPart == nil)
    }

    @Test("The left mouse button is bound from the panel; other buttons by pressing them")
    func mouseButtons() throws {
        let s = session()
        s.rightClickEmpty(at: point)
        #expect(s.inspector?.offersLeftClick == true)
        s.bindLeftClick()
        #expect(s.model.keymap().buttonModels.last?.keyName == "LMB")
        s.rightClickEmpty(at: CGPoint(x: 0.6, y: 0.6))
        #expect(s.bindMouseButton(1))
        #expect(s.model.keymap().buttonModels.last?.keyName == "RMB")
        #expect(!s.bindMouseButton(1))  // nothing selected: not used
    }

    @Test("Modifier keys other than Shift can't be bound; Shift can")
    func modifiers() throws {
        let s = session()
        s.rightClickEmpty(at: point)
        #expect(!s.bindKey(virtualKeyCode: 0x37, control: false))   // Command
        #expect(s.inspector?.isAwaitingKey == true)
        #expect(s.bindKey(virtualKeyCode: 0x38, control: false))    // Shift
        #expect(s.model.keymap().buttonModels.last?.keyName == "Lshft")
    }

    @Test("A controller button binds the selected control")
    func controller() {
        let s = session()
        s.rightClickEmpty(at: point)
        s.bindController("Button A")
        #expect(s.model.keymap().buttonModels.last?.keyName == "Button A")
    }

    // MARK: Moving, sizing, deleting, undo

    @Test("A drag is one undo step")
    func dragUndo() throws {
        let s = session()
        let id = try #require(s.elements.first { if case .button = $0.kind { true } else { false } }?.id)
        s.select(id)
        for _ in 0..<5 { s.moveSelected(by: CGVector(dx: 0.01, dy: 0)) }
        s.endMove()
        #expect(abs((s.model.keymap().buttonModels.first?.transform.xCoord ?? 0) - 0.85) < 1e-9)
        s.undo()
        #expect(abs((s.model.keymap().buttonModels.first?.transform.xCoord ?? 0) - 0.8) < 1e-9)
        s.redo()
        #expect(abs((s.model.keymap().buttonModels.first?.transform.xCoord ?? 0) - 0.85) < 1e-9)
    }

    @Test("Dragging the resize handle sets the size directly, and the whole drag is one undo step")
    func handleResize() throws {
        let s = session()
        let stick = try #require(s.elements.first { if case .joystick = $0.kind { true } else { false } })
        s.select(stick.id)
        s.setSelectedSize(26)
        s.setSelectedSize(31)
        s.endMove()
        #expect(s.model.keymap().joystickModel.first?.transform.size == 31)
        s.setSelectedSize(500) // clamped
        s.endMove()
        #expect(s.model.keymap().joystickModel.first?.transform.size == KeymapEditorModel.sizeRange.upperBound)
        s.undo(); s.undo()
        #expect(s.model.keymap() == map())
    }

    @Test("Resize, mode and delete work on the selection and can be undone")
    func editSelection() throws {
        let s = session()
        let stick = try #require(s.elements.first { if case .joystick = $0.kind { true } else { false } })
        s.select(stick.id)
        s.resizeSelected(larger: true)
        #expect((s.model.keymap().joystickModel.first?.transform.size ?? 0) > 20)
        #expect(s.inspector?.modeToggle?.isOn == false)
        s.toggleSelectedMode()
        #expect(s.inspector?.modeToggle?.isOn == true)
        s.deleteSelected()
        #expect(s.model.keymap().joystickModel.isEmpty)
        s.undo(); s.undo(); s.undo()
        #expect(s.model.keymap() == map())
        #expect(!s.canUndo && s.canRedo)
    }

    @Test("History is bounded")
    func historyLimit() {
        let s = session()
        for _ in 0..<(MapperSession.historyLimit + 20) { s.place(.joystick, at: point) }
        var steps = 0
        while s.canUndo { s.undo(); steps += 1 }
        #expect(steps == MapperSession.historyLimit)
    }

    // MARK: Closing

    @Test("Save finishes with save; Cancel with no changes finishes without asking")
    func finish() {
        let s = session()
        s.requestFinish(save: false)
        #expect(fake.finished == [false] && s.prompt == .none)
        let t = session()
        t.rightClickEmpty(at: point)
        _ = t.bindKey(virtualKeyCode: 0x0E, control: false)
        t.requestFinish(save: true)
        #expect(fake.finished == [false, true])
    }

    @Test("Cancel with unsaved changes asks, and only discards when confirmed")
    func cancelAsks() {
        let s = session()
        s.rightClickEmpty(at: point)
        _ = s.bindKey(virtualKeyCode: 0x0E, control: false)
        s.requestFinish(save: false)
        #expect(s.prompt == .confirmDiscard && fake.finished.isEmpty)
        s.cancelPrompt()
        #expect(fake.finished.isEmpty)
        s.requestFinish(save: false)
        s.confirmDiscard()
        #expect(fake.finished == [false])
    }

    @Test("Escape closes a prompt and does not bind")
    func escape() {
        let s = session()
        s.clickEmpty(at: point)
        #expect(s.bindKey(virtualKeyCode: 0x35, control: false))
        #expect(s.prompt == .none)
        #expect(s.elements.count == 2)
    }

    // MARK: Profiles

    @Test("Switching profile with no changes just switches")
    func switchClean() {
        fake.stored["Combat"] = map()
        let s = session()
        s.requestProfile("Combat")
        #expect(fake.switched.count == 1 && fake.switched[0].name == "Combat" && fake.switched[0].saved == nil)
        #expect(s.profile == "Combat" && s.message?.isError == false)
    }

    @Test("Switching with unsaved changes asks; Save writes the draft first, Discard drops it")
    func switchDirty() throws {
        let s = session()
        s.rightClickEmpty(at: point)
        _ = s.bindKey(virtualKeyCode: 0x0E, control: false)
        s.requestProfile("Combat")
        #expect(s.prompt == .confirmLeave(.profile("Combat")) && fake.switched.isEmpty)
        s.confirmLeave(save: true)
        let saved = try #require(fake.switched.first?.saved)
        #expect(saved.buttonModels.count == 2)
        let t = session()
        t.rightClickEmpty(at: point)
        _ = t.bindKey(virtualKeyCode: 0x0E, control: false)
        t.requestProfile("Combat")
        t.confirmLeave(save: false)
        #expect(fake.switched.last?.saved == nil)
    }

    @Test("A failed switch keeps the draft and says why")
    func switchFails() {
        let s = session()
        s.rightClickEmpty(at: point)
        _ = s.bindKey(virtualKeyCode: 0x0E, control: false)
        fake.failNext = "That profile could not be read."
        s.requestProfile("Combat")
        s.confirmLeave(save: false)
        #expect(s.profile == "Genshin")
        #expect(s.message == MapperSession.Message(text: "That profile could not be read.", isError: true))
        #expect(s.model.keymap().buttonModels.count == 2)   // the draft is still there
    }

    @Test("A copy of the draft is saved under a new name, leaving the profile as it was")
    func copy() throws {
        let s = session()
        s.rightClickEmpty(at: point)
        _ = s.bindKey(virtualKeyCode: 0x0E, control: false)
        s.requestCopyAsNewProfile()
        #expect(s.capturesText && s.suggestedName == "Genshin copy")
        s.submitName("  Boss fights ")
        #expect(fake.created.count == 1 && fake.created[0].name == "Boss fights")
        #expect(fake.created[0].saved == nil)                                // the old profile is not rewritten
        #expect(fake.created[0].keymap?.buttonModels.count == 2)
        #expect(s.profile == "Boss fights" && !s.hasUnsavedChanges && !s.capturesText)
    }

    @Test("A new blank profile starts empty, after asking about unsaved changes")
    func blank() throws {
        let s = session()
        s.requestNewBlankProfile()
        s.submitName("")
        #expect(s.message?.isError == true && s.capturesText)   // asks again
        s.submitName("Empty")
        #expect(fake.created.last?.name == "Empty" && fake.created.last?.keymap == nil)
        #expect(s.elements.isEmpty && s.profile == "Empty")

        let t = session()
        t.rightClickEmpty(at: point)
        _ = t.bindKey(virtualKeyCode: 0x0E, control: false)
        t.requestNewBlankProfile()
        t.submitName("Other")
        #expect(t.prompt == .confirmLeave(.newBlank(name: "Other")))
        t.confirmLeave(save: true)
        #expect(fake.created.last?.saved?.buttonModels.count == 2)
    }

    @Test("A name that is taken is made unique by the profile store, and the session follows it")
    func uniqueName() {
        let s = session()
        s.requestCopyAsNewProfile()
        s.submitName("combat")
        #expect(s.profile == "combat 2")
    }

    @Test("Picking the profile in use does nothing")
    func sameProfile() {
        let s = session()
        s.requestProfile("Genshin")
        #expect(fake.switched.isEmpty && s.prompt == .none)
    }

    // MARK: Layers, tips, conflicts

    @Test("Tips follow what the player is doing")
    func tips() {
        let empty = session(KeymappingData(bundleIdentifier: "g"))
        #expect(empty.tip?.contains("Right-click") == true)
        let s = session()
        #expect(s.tip?.contains("Click a control") == true)
        s.rightClickEmpty(at: point)
        #expect(s.tip?.contains("Press a key") == true)
    }

    @Test("Two controls on one key are reported")
    func conflicts() throws {
        let s = session()
        s.rightClickEmpty(at: point)
        _ = s.bindKey(virtualKeyCode: 0x0E, control: false)   // E again
        #expect(s.conflictSummary != nil)
        #expect(s.conflictingIDs.count == 2)
    }

    @Test("A key pressed with nothing selected on the base layer is used up and changes nothing")
    func strayKey() {
        let s = session()
        #expect(s.bindKey(virtualKeyCode: 0x0E, control: false))
        #expect(!s.hasUnsavedChanges && !s.canUndo)
    }

    @Test("A new layer takes the next key as its hold key")
    func layers() throws {
        let s = session()
        s.addLayer()
        #expect(s.currentLayer == 1 && s.layerCount == 1)
        _ = s.bindKey(virtualKeyCode: 0x38, control: false)   // Shift
        #expect(s.model.keymap().mulgLayers?.first?.holdKeyName == "Lshft" || s.layerTitle.contains("Lshft"))
        s.showLayer(offset: 1)
        #expect(s.currentLayer == 0)
    }

    @Test("A change of window shape refits the draft and is not an edit")
    func reflow() {
        var keymap = map()
        keymap.mulgAspectRatio = 16.0 / 9
        let s = session(keymap)
        s.rightClickEmpty(at: point)
        _ = s.bindKey(virtualKeyCode: 0x0E, control: false)
        #expect(s.canUndo)
        s.reflow(toAspect: 16.0 / 10)
        #expect(!s.canUndo)
    }

    @Test("The overlay is told about every change")
    func observes() {
        let s = session()
        var calls = 0
        s.onChange = { calls += 1 }
        let before = s.revision
        s.clickEmpty(at: point)
        s.place(.joystick, at: point)
        #expect(calls >= 2 && s.revision > before)
    }

    // MARK: Review fixes: stray input must not damage a control

    @Test("A right click with a joystick selected drops a skill button; it never turns the joystick mouse-driven")
    func rightClickNearJoystick() throws {
        let s = session()
        let stick = try #require(s.elements.first { if case .joystick = $0.kind { true } else { false } })
        s.select(stick.id)
        #expect(s.mouseButton(1, pointerAt: point))
        let saved = s.model.keymap()
        #expect(saved.joystickModel.first?.keyName == "Keyboard")      // untouched
        #expect(saved.buttonModels.count == 2)                          // the new skill button
        #expect(s.inspector?.tool == .skill && s.inspector?.isAwaitingKey == true)
    }

    @Test("A middle click with nothing to bind is not used")
    func middleClick() {
        let s = session()
        #expect(!s.mouseButton(2, pointerAt: point))
    }

    @Test("A right click binds a waiting control, a control under the pointer, or a picked joystick direction; elsewhere it adds")
    func rightClickRouting() throws {
        let s = session()
        // A just-placed control waits for a key: the right button is that key.
        s.rightClickEmpty(at: point)
        #expect(s.mouseButton(1, pointerAt: CGPoint(x: 0.9, y: 0.9)))
        #expect(s.model.keymap().buttonModels.last?.keyName == "RMB")
        #expect(s.model.keymap().buttonModels.count == 2)

        // A bound control selected to resize it keeps its key when the pointer is elsewhere...
        let id = try #require(s.elements.first { if case .button = $0.kind, $0.title == "E" { true } else { false } }?.id)
        s.select(id)
        #expect(s.mouseButton(1, pointerAt: point, overSelection: false))
        #expect(s.model.keymap().buttonModels.first?.keyName == "E")
        #expect(s.model.keymap().buttonModels.count == 3)
        // ...and takes the button when the pointer is on it.
        s.select(id)
        #expect(s.mouseButton(1, pointerAt: point, overSelection: true))
        #expect(s.model.keymap().buttonModels.first?.keyName == "RMB")

        // A joystick direction picked: the button goes to that direction.
        let t = session()
        let stick = try #require(t.elements.first { if case .joystick = $0.kind { true } else { false } })
        t.select(stick.id, part: .up)
        #expect(t.mouseButton(1, pointerAt: point))
        #expect(t.model.keymap().joystickModel.first?.upKeyCode == KeymapKeyNames.rightMouseCode)
    }

    @Test("A stray key does nothing to a camera or to a keyboard joystick with no direction chosen")
    func strayKeys() throws {
        let s = session(KeymappingData(bundleIdentifier: "g"))
        s.place(.camera, at: point)
        let camera = s.model.keymap()
        #expect(s.bindKey(virtualKeyCode: 0x0E, control: false))
        #expect(s.model.keymap() == camera && s.undoDepth == 1)          // only the placement is on the undo list
        #expect(s.model.keymap().mouseAreaModel.count == 1 && s.model.keymap().draggableButtonModels.isEmpty)

        s.place(.joystick, at: CGPoint(x: 0.2, y: 0.7))
        let steps = s.undoDepth
        let before = s.model.keymap()
        #expect(s.bindKey(virtualKeyCode: 0x0E, control: false))
        #expect(s.model.keymap() == before && s.undoDepth == steps)
        // A direction is chosen, then the key binds.
        let stick = try #require(s.elements.first { if case .joystick = $0.kind { true } else { false } })
        s.select(stick.id, part: .up)
        #expect(s.bindKey(virtualKeyCode: 0x0E, control: false))
        #expect(s.model.keymap().joystickModel.first?.upKeyCode == 8)
    }

    @Test("Discarding a control left without a key leaves nothing to undo for it")
    func discardIsNotAnUndoStep() {
        let s = session()
        s.rightClickEmpty(at: point)
        s.clickEmpty(at: point)                         // clicked away: discarded
        #expect(!s.canUndo)
        s.rightClickEmpty(at: point)
        s.resizeSelected(larger: true)                  // something else was done to it first
        s.clickEmpty(at: point)
        #expect(s.canUndo)                              // those steps stay
        s.undo(); s.undo()
        #expect(s.model.keymap() == map())
    }

    @Test("A key that sets a layer's hold key says so")
    func layerKeyFeedback() {
        let s = session()
        s.addLayer()
        _ = s.bindKey(virtualKeyCode: 0x38, control: false)   // Shift
        #expect(s.message?.text == "Hold Left Shift to use this layer" && s.message?.isError == false)
    }

    @Test("The panel for a camera tells the player to add a Drag area for a held key")
    func cameraDetail() {
        let s = session(KeymappingData(bundleIdentifier: "g"))
        s.place(.camera, at: point)
        #expect(s.inspector?.detail.contains("Drag area") == true)
    }

    @Test("Escape with nothing selected closes (asking first when there are changes); with a control selected it binds")
    func escapeCloses() {
        let clean = session()
        _ = clean.bindKey(virtualKeyCode: 0x35, control: false)
        #expect(fake.finished == [false])

        let dirty = session()
        dirty.rightClickEmpty(at: point)
        _ = dirty.bindKey(virtualKeyCode: 0x0E, control: false)      // E bound, nothing selected
        _ = dirty.bindKey(virtualKeyCode: 0x35, control: false)
        #expect(dirty.prompt == .confirmDiscard && fake.finished == [false])

        let selected = session()
        selected.rightClickEmpty(at: point)
        _ = selected.bindKey(virtualKeyCode: 0x35, control: false)   // Esc is bindable
        #expect(selected.model.keymap().buttonModels.last?.keyName == "Esc")
        #expect(fake.finished == [false])
    }
}
