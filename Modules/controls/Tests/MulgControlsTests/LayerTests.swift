import CoreGraphics
import Foundation
import MulgContracts
@testable import MulgControls
import Testing

@Suite("Keymap layers") @MainActor
struct DispatcherLayerTests {
    private func dispatcher(log: @escaping (String) -> Void) -> ActionDispatcher {
        let dispatcher = ActionDispatcher()
        dispatcher.register(key: "E") { pressed in log("base E \(pressed)") }
        dispatcher.register(key: "F") { pressed in log("base F \(pressed)") }
        dispatcher.beginLayer(1, holdKey: "Q")
        dispatcher.register(key: "E") { pressed in log("boat E \(pressed)") }
        dispatcher.endLayer()
        return dispatcher
    }

    @Test("While the layer is held, its keys win and others fall through to the base")
    func routing() {
        var log: [String] = []
        let dispatcher = dispatcher { log.append($0) }
        #expect(dispatcher.layer(heldBy: "Q") == 1)
        dispatcher.setActiveLayer(1)
        dispatcher.dispatch(key: "E", pressed: true)
        dispatcher.dispatch(key: "E", pressed: false)
        dispatcher.dispatch(key: "F", pressed: true)
        dispatcher.dispatch(key: "F", pressed: false)
        #expect(log == ["boat E true", "boat E false", "base F true", "base F false"])
    }

    @Test("A key's release goes where its press went, even if the layer changed")
    func releaseFollowsPress() {
        var log: [String] = []
        let dispatcher = dispatcher { log.append($0) }
        dispatcher.dispatch(key: "E", pressed: true)
        dispatcher.setActiveLayer(1)
        dispatcher.dispatch(key: "E", pressed: false)
        #expect(log == ["base E true", "base E false"])
    }

    @Test("Clearing forgets layers")
    func clear() {
        let dispatcher = dispatcher { _ in }
        dispatcher.setActiveLayer(1)
        dispatcher.clear()
        #expect(dispatcher.activeLayer == 0)
        #expect(dispatcher.layer(heldBy: "Q") == nil)
    }
}

@Suite("Keymap editor layers")
struct EditorLayerTests {
    @Test("A new layer takes the next key as its hold key and saves its own elements")
    func newLayer() throws {
        var model = KeymapEditorModel(keymap: KeymappingData(bundleIdentifier: "g"))
        model.add(.button, at: CGPoint(x: 0.5, y: 0.5))
        model.assignKey(code: 8, name: "E")
        model.addLayer()
        #expect(model.currentLayer == 1)
        #expect(model.visibleElements.isEmpty)
        model.assignKey(code: 20, name: "Q")
        model.add(.button, at: CGPoint(x: 0.2, y: 0.2))
        model.assignKey(code: 8, name: "E")
        let keymap = model.keymap()
        #expect(keymap.buttonModels.count == 1)
        let layer = try #require(keymap.mulgLayers?.first)
        #expect(layer.holdKeyName == "Q")
        #expect(layer.buttonModels.map(\.keyName) == ["E"])
        #expect(model.conflicts.isEmpty, "the same key in two layers is fine")
    }

    @Test("Layers round-trip, and an unused new layer is not saved")
    func roundTrip() {
        var keymap = KeymappingData(bundleIdentifier: "g")
        var layer = KeymapLayer(name: "Boat", holdKeyCode: 20, holdKeyName: "Q")
        layer.buttonModels = [ButtonElement(keyCode: 8, keyName: "E", transform: KeyModelTransform(size: 5, xCoord: 0.5, yCoord: 0.5))]
        keymap.mulgLayers = [layer]
        var model = KeymapEditorModel(keymap: keymap)
        #expect(model.keymap() == keymap)
        model.addLayer()
        #expect(model.keymap() == keymap)
        model.showLayer(offset: 1)
        #expect(model.currentLayer == 0, "wraps back to the base keymap")
    }

    @Test("Control+key can't hold a layer")
    func noControlHoldKey() {
        var model = KeymapEditorModel(keymap: KeymappingData(bundleIdentifier: "g"))
        model.addLayer()
        model.assignKey(code: KeymapKeyNames.defaultCode, name: "⌃Q")
        #expect(model.layers.first?.hasHoldKey == false)
    }
}
