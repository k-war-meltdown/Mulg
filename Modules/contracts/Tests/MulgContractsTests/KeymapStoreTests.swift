import Foundation
@testable import MulgContracts
@testable import MulgKeymaps
import Testing

@Suite("Keymap store")
struct KeymapStoreTests {
    let store: KeymapStore

    init() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("keymaps-\(UUID().uuidString)")
        store = KeymapStore(folder: folder, bundleIdentifier: "com.example.game")
    }

    private func write(_ names: [String], order: [String]) {
        for name in names {
            store.write(KeymappingData(bundleIdentifier: "com.example.game"), to: store.keymapFile(named: name))
        }
        // Stored URLs from another home folder are re-rooted by name.
        let old = URL(fileURLWithPath: "/Users/someone-else/Library/Containers/io.mulg.Mulg/Keymapping/x")
        store.writeConfig(KeymapConfig(defaultKm: old.appendingPathComponent("\(order[0]).plist"),
                                       keymapOrder: order.map { old.appendingPathComponent("\($0).plist") }))
    }

    @Test("Keymaps follow the config order, then other files by name")
    func order() {
        write(["default", "combat", "boat", "extra"], order: ["default", "combat", "boat"])
        let names = store.orderedKeymapFiles().map { $0.deletingPathExtension().lastPathComponent }
        #expect(names == ["default", "combat", "boat", "extra"])
    }

    @Test func missingDefaultDoesNotRewriteTheExistingListOrInventAnEmptyMap() throws {
        defer { try? FileManager.default.removeItem(at: store.folder) }
        write(["combat", "boat"], order: ["gone", "boat", "combat"])
        let before = try Data(contentsOf: store.configFile)
        let loaded = store.loadDefault()
        #expect(!loaded.problems.isEmpty)
        #expect(try Data(contentsOf: store.configFile) == before)
        #expect(!FileManager.default.fileExists(atPath: loaded.file.path))
        #expect(store.orderedKeymapFiles().map(\.lastPathComponent) == ["boat.plist", "combat.plist"])
    }

    @Test func unreadableMapsAndListsAreKeptUntilExplicitRepair() throws {
        defer { try? FileManager.default.removeItem(at: store.folder) }
        write(["default", "combat"], order: ["default", "combat"])
        let file = store.keymapFile(named: "default"), damaged = Data("damaged".utf8)
        try damaged.write(to: file)
        #expect(!store.loadDefault().problems.isEmpty)
        #expect(store.write(KeymappingData(bundleIdentifier: store.bundleIdentifier), to: file) != nil)
        #expect(try Data(contentsOf: file) == damaged)
        try damaged.write(to: store.configFile)
        #expect(!store.loadDefault().problems.isEmpty)
        let repaired = KeymapConfig(defaultKm: file, keymapOrder: [file, store.keymapFile(named: "combat")])
        #expect(store.writeConfig(repaired) != nil)
        #expect(try Data(contentsOf: store.configFile) == damaged)
        #expect(store.writeConfig(repaired, replacingUnreadable: true) == nil)
        #expect(store.write(KeymappingData(bundleIdentifier: store.bundleIdentifier), to: file, replacingUnreadable: true) == nil)
        #expect(store.loadDefault().problems.isEmpty)
    }

    @Test func anAbsentListDiscoversExistingMapsWithoutReplacingThem() throws {
        defer { try? FileManager.default.removeItem(at: store.folder) }
        let file = store.keymapFile(named: "combat")
        var map = KeymappingData(bundleIdentifier: store.bundleIdentifier)
        map.buttonModels = [ButtonElement(keyCode: 4, keyName: "A", transform: .init(size: 5, xCoord: 0.5, yCoord: 0.5))]
        #expect(store.write(map, to: file) == nil)
        let original = try Data(contentsOf: file)
        #expect(store.loadDefault().keymap == map)
        #expect(try Data(contentsOf: file) == original)
        #expect(store.orderedKeymapFiles() == [file])
    }

    @Test("Next and previous wrap around")
    func switching() {
        write(["default", "combat"], order: ["default", "combat"])
        let first = store.keymapFile(named: "default")
        #expect(store.keymapFile(offset: 1, from: first)?.lastPathComponent == "combat.plist")
        #expect(store.keymapFile(offset: -1, from: first)?.lastPathComponent == "combat.plist")
        #expect(store.keymapFile(offset: 2, from: first)?.lastPathComponent == "default.plist")
    }

    @Test("Missing files in the config are skipped")
    func missingFiles() {
        write(["default"], order: ["default", "gone"])
        #expect(store.orderedKeymapFiles().map(\.lastPathComponent) == ["default.plist"])
    }

    @Test("Loading a keymap from a newer format is refused")
    func tooNew() throws {
        var future = KeymappingData(bundleIdentifier: "com.example.game")
        future.version = "3.0.0"
        let file = store.keymapFile(named: "future")
        store.write(future, to: file)
        let loaded = store.load(file)
        #expect(loaded.problems == [.keymapTooNew(file: file.path, version: "3.0.0")])
        #expect(loaded.keymap.buttonModels.isEmpty)
        let original = try Data(contentsOf: file)
        #expect(store.write(loaded.keymap, to: file) == .keymapTooNew(file: file.path, version: "3.0.0"))
        #expect(try Data(contentsOf: file) == original)
    }
}

@Suite("Keymap layers and conflicts")
struct KeymapLayerTests {
    private func transform() -> KeyModelTransform { KeyModelTransform(size: 5, xCoord: 0.5, yCoord: 0.5) }

    @Test("Layers survive a save and load; keymaps without them still decode")
    func roundTrip() throws {
        var keymap = KeymappingData(bundleIdentifier: "g")
        var layer = KeymapLayer(name: "Boat", holdKeyCode: 20, holdKeyName: "Q")
        layer.buttonModels = [ButtonElement(keyCode: 8, keyName: "E", transform: transform())]
        keymap.mulgLayers = [layer]
        let data = try PropertyListEncoder().encode(keymap)
        #expect(try PropertyListDecoder().decode(KeymappingData.self, from: data) == keymap)

        keymap.mulgLayers = nil
        let plain = try PropertyListEncoder().encode(keymap)
        #expect(try PropertyListDecoder().decode(KeymappingData.self, from: plain).mulgLayers == nil)
    }

    @Test("The same key twice in one layer is a conflict; across layers it is not")
    func conflicts() {
        var keymap = KeymappingData(bundleIdentifier: "g")
        keymap.buttonModels = [ButtonElement(keyCode: 8, keyName: "E", transform: transform())]
        keymap.joystickModel = [JoystickElement(upKeyCode: 26, rightKeyCode: 7, downKeyCode: 22, leftKeyCode: 8,
                                                transform: transform())]
        var layer = KeymapLayer(name: "Boat", holdKeyCode: 20, holdKeyName: "Q")
        layer.buttonModels = [ButtonElement(keyCode: 8, keyName: "E", transform: transform())]
        keymap.mulgLayers = [layer]
        let found = KeymapConflicts.find(in: keymap)
        #expect(found == [KeymapConflict(key: "E", layer: nil, uses: ["button", "joystick left"])])
    }

    @Test("A layer key that is also a normal binding is reported")
    func holdKeyHidesBinding() {
        var keymap = KeymappingData(bundleIdentifier: "g")
        keymap.buttonModels = [ButtonElement(keyCode: 20, keyName: "Q", transform: transform())]
        keymap.mulgLayers = [KeymapLayer(name: "Boat", holdKeyCode: 20, holdKeyName: "Q")]
        #expect(KeymapConflicts.find(in: keymap).map(\.key) == ["Q"])
    }

    @Test("A draggable's move source may share the mouse with the camera")
    func draggableMouse() {
        var keymap = KeymappingData(bundleIdentifier: "g")
        keymap.mouseAreaModel = [MouseAreaElement(transform: transform())]
        keymap.draggableButtonModels = [ButtonElement(keyCode: 21, keyName: "Mouse", transform: transform())]
        #expect(KeymapConflicts.find(in: keymap).isEmpty)
    }
}

@Suite("Keymaps follow the screen")
struct KeymapFitTests {
    func keymap(aspect: Double?) -> KeymappingData {
        var keymap = KeymappingData(bundleIdentifier: "com.example.game")
        keymap.mulgAspectRatio = aspect
        keymap.buttonModels = [
            ButtonElement(keyCode: 4, keyName: "A", transform: KeyModelTransform(size: 8, xCoord: 0.1, yCoord: 0.9)),
            ButtonElement(keyCode: 5, keyName: "B", transform: KeyModelTransform(size: 8, xCoord: 0.5, yCoord: 0.5)),
            ButtonElement(keyCode: 6, keyName: "C", transform: KeyModelTransform(size: 8, xCoord: 0.9, yCoord: 0.2))
        ]
        return keymap
    }

    @Test("4K and 5K are the same shape as 1080p, so nothing moves")
    func sameShape() {
        let fitted = keymap(aspect: 16.0 / 9).fitted(toWidth: 2560, height: 1440)
        // Fitting records each control's inferred edge anchor; the geometry is what must not move.
        let geometry = { (models: [ButtonElement]) in models.map { [$0.transform.size, $0.transform.xCoord, $0.transform.yCoord] } }
        #expect(geometry(fitted.buttonModels) == geometry(keymap(aspect: nil).buttonModels))
    }

    @Test("From the iPad screen (4:3) to 16:9, controls keep their distance from their edge, in heights")
    func iPadTo16by9() {
        let fitted = keymap(aspect: 4.0 / 3).fitted(toWidth: 1920, height: 1080)
        let t = fitted.buttonModels.map(\.transform)
        #expect(abs(t[0].xCoord - 0.075) < 0.0001)
        #expect(abs(t[1].xCoord - 0.5) < 0.0001)
        #expect(abs(t[2].xCoord - 0.925) < 0.0001)
        #expect(t[0].yCoord == 0.9)
        #expect(abs(t[0].size - 6) < 0.0001)
        #expect(fitted.mulgAspectRatio == 1920.0 / 1080)
    }

    @Test("A keymap with no recorded shape is left where it is")
    func unknownShape() {
        let fitted = keymap(aspect: nil).fitted(toWidth: 1920, height: 1080)
        #expect(fitted.buttonModels == keymap(aspect: nil).buttonModels)
    }

    @Test("Genshin on the iPad screen: the burst stays left of the skill, the pick-up prompt follows the centre")
    func genshinTo4by3() {
        var keymap = KeymappingData(bundleIdentifier: "com.miHoYo.GenshinImpact")
        keymap.mulgAspectRatio = 16.0 / 9
        keymap.buttonModels = [
            ButtonElement(keyCode: 20, keyName: "Q", transform: KeyModelTransform(size: 5, xCoord: 0.64, yCoord: 0.9)),
            ButtonElement(keyCode: 8, keyName: "E", transform: KeyModelTransform(size: 5, xCoord: 0.73, yCoord: 0.9)),
            ButtonElement(keyCode: 9, keyName: "F", transform: KeyModelTransform(size: 4, xCoord: 0.6, yCoord: 0.5))
        ]
        let x = keymap.fitted(toWidth: 1376, height: 1032).buttonModels.map(\.transform.xCoord)
        // Burst left of skill holds under either policy.
        #expect(x[0] < x[1])
        // On a narrower screen controls shrink by scaleInHeights (0.75 here) and keep their fraction of the
        // width: the horizontal factor is (16/9) / (4/3) × 0.75 = 1, whichever anchor each one has.
        #expect(abs(x[0] - 0.64) < 0.0001)
        #expect(abs(x[1] - 0.73) < 0.0001)
        #expect(abs(x[2] - 0.6) < 0.0001)
    }
}

extension KeymapStoreTests {
    @Test("Touch mode selects a touch profile instead of an empty native-only map without rewriting storage")
    func touchFallback() throws {
        defer { try? FileManager.default.removeItem(at: store.folder) }
        var native = KeymappingData(bundleIdentifier: store.bundleIdentifier)
        native.mulgControllerBindings = [ControllerBinding(keyCode: 26, element: .leftStickUp)]
        var touch = KeymappingData(bundleIdentifier: store.bundleIdentifier)
        touch.draggableButtonModels = [ButtonElement(keyCode: 8, keyName: "E",
            transform: KeyModelTransform(size: 10, xCoord: 0.9, yCoord: 0.7))]
        let nativeFile = store.keymapFile(named: "Native"), touchFile = store.keymapFile(named: "Touch")
        #expect(store.write(native, to: nativeFile) == nil)
        #expect(store.write(touch, to: touchFile) == nil)
        #expect(store.writeConfig(KeymapConfig(defaultKm: nativeFile, keymapOrder: [nativeFile, touchFile])) == nil)
        let before = try Data(contentsOf: store.configFile)
        let loaded = store.loadTouchDefault()
        #expect(loaded.problems.isEmpty && loaded.file == touchFile && loaded.keymap == touch)
        #expect(try Data(contentsOf: store.configFile) == before)
        #expect(store.loadDefault().keymap == native)
        #expect(native.hasTouchControls == false && touch.hasTouchControls)
    }

    @Test("Missing touchscreen bindings are reported without destroying a native profile")
    func missingTouchProfile() throws {
        defer { try? FileManager.default.removeItem(at: store.folder) }
        var native = KeymappingData(bundleIdentifier: store.bundleIdentifier)
        native.mulgControllerBindings = [ControllerBinding(keyCode: 26, element: .leftStickUp)]
        let file = store.keymapFile(named: "Native")
        #expect(store.write(native, to: file) == nil)
        #expect(store.writeConfig(KeymapConfig(defaultKm: file, keymapOrder: [file])) == nil)
        let before = try Data(contentsOf: file)
        #expect(!store.loadTouchDefault().problems.isEmpty)
        #expect(try Data(contentsOf: file) == before)
    }
}