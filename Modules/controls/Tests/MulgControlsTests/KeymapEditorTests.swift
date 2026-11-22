import CoreGraphics
import Foundation
import MulgContracts
@testable import MulgControls
import Testing

@Suite("Keymap editor")
struct KeymapEditorTests {
    private func keymap() -> KeymappingData {
        var keymap = KeymappingData(bundleIdentifier: "com.miHoYo.GenshinImpact")
        keymap.buttonModels = [ButtonElement(keyCode: 8, keyName: "E", transform: KeyModelTransform(size: 5, xCoord: 0.8, yCoord: 0.8))]
        keymap.joystickModel = [JoystickElement(upKeyCode: 26, rightKeyCode: 7, downKeyCode: 22, leftKeyCode: 4,
                                                transform: KeyModelTransform(size: 20, xCoord: 0.2, yCoord: 0.7))]
        keymap.mulgControllerBindings = [ControllerBinding(keyCode: 8, element: .buttonY)]
        return keymap
    }

    @Test("Opening and saving without changes gives the same keymap")
    func roundTrip() {
        let model = KeymapEditorModel(keymap: keymap())
        #expect(model.keymap() == keymap())
        #expect(!model.hasChanges)
        #expect(model.focused == nil)
    }

    @Test("Saving keeps controller bindings (upstream dropped them)")
    func keepsControllerBindings() throws {
        var model = KeymapEditorModel(keymap: keymap())
        model.add(.button, at: CGPoint(x: 0.5, y: 0.5))
        #expect(model.keymap().mulgControllerBindings == keymap().mulgControllerBindings)
        #expect(model.keymap().buttonModels.count == 2)
    }

    @Test("Both joystick types can be added: fixed and floating")
    func bothJoystickTypes() {
        var model = KeymapEditorModel(keymap: KeymappingData(bundleIdentifier: "g"))
        model.add(.joystick, at: CGPoint(x: 0.2, y: 0.8))
        model.add(.floatingJoystick, at: CGPoint(x: 0.25, y: 0.75))
        #expect(model.keymap().joystickModel.map(\.effectiveMode) == [.FIXED, .FLOATING])
        #expect(KeymapEditorModel.NewElement.allCases.contains(.floatingJoystick))
    }

    @Test("A new button takes the next key pressed")
    func bindButton() throws {
        var model = KeymapEditorModel(keymap: KeymappingData(bundleIdentifier: "g"))
        let id = model.add(.button, at: CGPoint(x: 0.5, y: 0.5))
        #expect(model.focused == id)
        model.assignKey(code: 9, name: "F")
        let button = try #require(model.keymap().buttonModels.first)
        #expect(button.keyCode == 9)
        #expect(button.keyName == "F")
        model.assignMouseButton(code: KeymapKeyNames.rightMouseCode, name: "RMB")
        #expect(model.keymap().buttonModels.first?.keyName == "RMB")
        model.assignControllerElement("Button A")
        #expect(model.keymap().buttonModels.first?.keyName == "Button A")
        #expect(model.keymap().buttonModels.first?.keyCode == KeymapKeyNames.defaultCode)
    }

    @Test("Joystick directions are rebound one at a time")
    func joystickParts() throws {
        var model = KeymapEditorModel(keymap: keymap())
        let joystick = try #require(model.elements.first { if case .joystick = $0.kind { true } else { false } })
        model.select(joystick.id, part: .up)
        model.assignKey(code: 82, name: "Up")
        let saved = try #require(model.keymap().joystickModel.first)
        #expect(saved.upKeyCode == 82)
        #expect(saved.downKeyCode == 22)
        #expect(!saved.isAnalog)
    }

    @Test("A thumbstick or mouse button makes a joystick analog; a key makes it a keyboard joystick again")
    func joystickSources() throws {
        var model = KeymapEditorModel(keymap: keymap())
        let joystick = try #require(model.elements.first { if case .joystick = $0.kind { true } else { false } })
        model.select(joystick.id)
        model.assignControllerElement("Left Thumbstick")
        #expect(model.keymap().joystickModel.first?.keyName == "Left Thumbstick")
        #expect(model.element(joystick.id)?.title(of: .up) == nil, "an analog stick has no direction keys")
        model.assignMouseButton(code: KeymapKeyNames.leftMouseCode, name: "LMB")
        #expect(model.keymap().joystickModel.first?.keyName == "Mouse")
        model.assignKey(code: 4, name: "A")
        #expect(model.keymap().joystickModel.first?.keyName == "Keyboard")
    }

    @Test("Gameplay keys never turn a camera area into a grabbed drag or change its map")
    func cameraRemainsIndependent() throws {
        var model = KeymapEditorModel(keymap: KeymappingData(bundleIdentifier: "g"))
        model.add(.cameraArea, at: CGPoint(x: 0.6, y: 0.4))
        let before = model.keymap()
        for (code, name) in [(21, "R"), (20, "Q"), (8, "E"), (58, "F1")] {
            model.assignKey(code: code, name: name)
            #expect(model.keymap() == before)
        }
        let camera = try #require(model.keymap().mouseAreaModel.first)
        #expect(camera.keyName == "Mouse" && camera.transform.xCoord == 0.6)
        #expect(model.keymap().draggableButtonModels.isEmpty)
    }

    @Test("Explicit skill buttons and aimed drags still accept R independently of the camera")
    func skillBindingsRemainEditable() {
        var model = KeymapEditorModel(keymap: KeymappingData(bundleIdentifier: "custom.game"))
        model.add(.cameraArea, at: CGPoint(x: 0.5, y: 0.5))
        model.add(.button, at: CGPoint(x: 0.8, y: 0.8)); model.assignKey(code: 21, name: "R")
        #expect(model.keymap().buttonModels.first?.keyCode == 21)
        model.add(.draggableButton, at: CGPoint(x: 0.85, y: 0.8)); model.assignKey(code: 8, name: "E")
        #expect(model.keymap().draggableButtonModels.first?.keyCode == 8)
        #expect(model.keymap().mouseAreaModel.first?.keyName == "Mouse")
    }

    @Test("Moving is clamped to the screen and sizes stay in range")
    func moveAndResize() throws {
        var model = KeymapEditorModel(keymap: KeymappingData(bundleIdentifier: "g"))
        model.add(.button, at: CGPoint(x: 0.9, y: 0.1))
        model.moveSelected(by: CGVector(dx: 0.5, dy: -0.5))
        let moved = try #require(model.keymap().buttonModels.first)
        #expect(moved.transform.xCoord == 1)
        #expect(moved.transform.yCoord == 0)
        for _ in 0..<60 { model.resizeSelected(larger: false) }
        #expect(model.keymap().buttonModels.first?.transform.size == KeymapEditorModel.sizeRange.lowerBound)
        for _ in 0..<80 { model.resizeSelected(larger: true) }
        #expect(model.keymap().buttonModels.first?.transform.size == KeymapEditorModel.sizeRange.upperBound)
    }

    @Test("Removing deletes only the selected element")
    func remove() {
        var model = KeymapEditorModel(keymap: keymap())
        let first = model.elements[0].id
        model.select(first)
        model.removeSelected()
        #expect(model.elements.count == 1)
        #expect(model.focused == nil)
        model.removeSelected()
        #expect(model.elements.count == 1, "nothing selected, nothing removed")
    }

    @Test("Joystick mode switches between fixed and floating")
    func joystickMode() throws {
        var model = KeymapEditorModel(keymap: keymap())
        let joystick = try #require(model.elements.first { if case .joystick = $0.kind { true } else { false } })
        model.select(joystick.id)
        model.toggleJoystickMode()
        #expect(model.keymap().joystickModel.first?.effectiveMode == .FLOATING)
        model.toggleJoystickMode()
        #expect(model.keymap().joystickModel.first?.effectiveMode == .FIXED)
    }

    @Test("A button switches between hold and toggle")
    func buttonHold() throws {
        var model = KeymapEditorModel(keymap: keymap())
        let button = try #require(model.elements.first { if case .button = $0.kind { true } else { false } })
        model.select(button.id)
        model.toggleButtonHold()
        #expect(model.keymap().buttonModels.first?.toggle == true)
        model.toggleButtonHold()
        #expect(model.keymap().buttonModels.first?.toggle == nil)
    }

    @Test("Elements sharing a key are marked; others are not")
    func conflictMarks() {
        var model = KeymapEditorModel(keymap: keymap())
        #expect(model.conflictingElements.isEmpty)
        let id = model.add(.button, at: CGPoint(x: 0.1, y: 0.1))
        model.assignKey(code: 26, name: "W")
        let joystick = model.elements.first { if case .joystick = $0.kind { true } else { false } }
        #expect(model.conflictingElements == Set([id, joystick?.id].compactMap { $0 }))
    }

    @Test("Nothing selected: inputs change nothing")
    func noSelection() {
        var model = KeymapEditorModel(keymap: keymap())
        model.assignKey(code: 9, name: "F")
        model.assignMouseButton(code: -2, name: "RMB")
        model.assignControllerElement("Button B")
        #expect(!model.hasChanges)
    }
}
