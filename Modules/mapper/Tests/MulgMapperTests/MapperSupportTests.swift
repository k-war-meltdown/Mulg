import CoreGraphics
import Foundation
import MulgContracts
import MulgKeymaps
@testable import MulgMapper
import Testing

@Suite("Mapper labels")
struct MapperLabelTests {
    @Test("Keys read the way players say them")
    func labels() {
        #expect(MapperKeyLabel.short("Lshft") == "⇧")
        #expect(MapperKeyLabel.short("Spc") == "Space")
        #expect(MapperKeyLabel.short("LMB") == "Click")
        #expect(MapperKeyLabel.short("RMB") == "R-Click")
        #expect(MapperKeyLabel.short("Left Thumbstick") == "L-Stick")
        #expect(MapperKeyLabel.short("Button A") == "A")
        #expect(MapperKeyLabel.short("cX") == "X")
        #expect(MapperKeyLabel.short("Keypad 7") == "N7")
        #expect(MapperKeyLabel.short("E") == "E")
        #expect(MapperKeyLabel.short("") == "?")
        #expect(MapperKeyLabel.short("A very long key name").count <= 7)
        #expect(MapperKeyLabel.long("Lshft") == "Left Shift")
        #expect(MapperKeyLabel.long("⌃W") == "Control + W")
        #expect(MapperKeyLabel.long("") == "nothing yet")
    }

    @Test("Every name the editor can assign has a label, and the labels are short")
    func everyKey() {
        for name in KeymapKeyNames.keyCodes.values {
            #expect(!MapperKeyLabel.short(name).isEmpty)
            #expect(MapperKeyLabel.short(name).count <= 7, "\(name)")
        }
    }
}

@Suite("Mapper tools")
struct MapperToolTests {
    @Test("Each tool places the control it is named for")
    func newElements() {
        #expect(MapperTool.joystick.newElement == .joystick)
        #expect(MapperTool.skill.newElement == .button)
        #expect(MapperTool.camera.newElement == .cameraArea)
        #expect(MapperTool.drag.newElement == .draggableButton)
        #expect(MapperTool.allCases.allSatisfy { !$0.title.isEmpty && !$0.subtitle.isEmpty && !$0.symbol.isEmpty })
    }

    @Test("Only controls that need a key start without one")
    func unbound() {
        #expect(MapperTool.allCases.filter(\.startsUnbound) == [.skill, .drag])
    }
}

@Suite("Mapper geometry")
struct MapperGeometryTests {
    private let canvas = CGSize(width: 1600, height: 900)
    private var metrics: ScreenMetrics { ScreenMetrics(width: 1600, height: 900) }

    @Test("Each rectangular edge moves independently and preserves the opposite edge")
    func rectangularEdges() throws {
        let original = CGRect(x: 600, y: 300, width: 200, height: 100)
        let right = MapperGeometry.resizing(original, edge: .right, to: CGPoint(x: 1000, y: 500), in: canvas)
        #expect(right == CGRect(x: 600, y: 300, width: 400, height: 100))
        let left = MapperGeometry.resizing(original, edge: .left, to: CGPoint(x: 500, y: 500), in: canvas)
        #expect(left.maxX == original.maxX && left.height == original.height && left.minX == 500)
        let top = MapperGeometry.resizing(original, edge: .top, to: CGPoint(x: 0, y: 200), in: canvas)
        #expect(top.maxY == original.maxY && top.width == original.width && top.minY == 200)
        let bottom = MapperGeometry.resizing(original, edge: .bottom, to: CGPoint(x: 0, y: 1000), in: canvas)
        #expect(bottom.maxY == canvas.height && bottom.width == original.width)
        let crossed = MapperGeometry.resizing(original, edge: .left, to: CGPoint(x: 1000, y: 0), in: canvas)
        #expect(crossed.width == MapperGeometry.minimumControlSide && crossed.maxX == original.maxX)
        let transform = KeyModelTransform(size: 5, xCoord: 0.5, yCoord: 0.5, widthScale: 3, heightScale: 1.5)
        let decoded = try PropertyListDecoder().decode(KeyModelTransform.self, from: PropertyListEncoder().encode(transform))
        #expect(MapperGeometry.frame(of: decoded, canvas: canvas, metrics: metrics).size == CGSize(width: 240, height: 120))
        let fitted = decoded.withAdaptiveHUDSamples(referenceAspect: 16.0 / 9).fitted(from: 16.0 / 9, to: 16.0 / 10)
        #expect(fitted.widthScale == 3 && fitted.heightScale == 1.5)
        let legacy = try JSONDecoder().decode(KeyModelTransform.self, from: Data("{\"size\":5,\"xCoord\":0.5,\"yCoord\":0.5}".utf8))
        #expect(legacy.effectiveWidthScale == 1 && legacy.effectiveHeightScale == 1)
    }

    @Test("A joystick is drawn at the finger's reach, and its handle maps back to the same size")
    func joystickReach() {
        // Size 20 on a 1600-wide canvas is 320 points; the finger reaches 80 from the centre: a 160 circle.
        let frame = MapperGeometry.frame(of: KeyModelTransform(size: 20, xCoord: 0.5, yCoord: 0.5), canvas: canvas,
                                         metrics: metrics, drawScale: MapperGeometry.joystickDrawScale)
        #expect(abs(frame.height - 160) < 0.01)
        #expect(abs(metrics.size(20) / 4 - frame.height / 2) < 0.01) // circle radius == runtime reach
        // The handle on the circle's right edge gives the size back; dragging it out 20 points grows it.
        let back = MapperGeometry.size(forHandleOffset: CGVector(dx: frame.width / 2, dy: 0), metrics: metrics,
                                       drawScale: MapperGeometry.joystickDrawScale)
        #expect(abs(back - 20) < 0.01)
        let grown = MapperGeometry.size(forHandleOffset: CGVector(dx: frame.width / 2 + 20, dy: 0), metrics: metrics,
                                        drawScale: MapperGeometry.joystickDrawScale)
        #expect(abs(grown - 25) < 0.01)
    }

    @Test("A control is drawn where the keymap puts it, at the keymap's size")
    func frame() {
        // 5 % of the longer side, centred at 80 % / 80 %.
        let frame = MapperGeometry.frame(of: KeyModelTransform(size: 5, xCoord: 0.8, yCoord: 0.8), canvas: canvas, metrics: metrics)
        #expect(abs(frame.midX - 1280) < 0.01 && abs(frame.midY - 720) < 0.01)
        #expect(abs(frame.width - 80) < 0.01 && abs(frame.height - 80) < 0.01)
    }

    @Test("A tiny control is still big enough to click, around the same centre")
    func minimum() {
        let frame = MapperGeometry.frame(of: KeyModelTransform(size: 0.5, xCoord: 0.5, yCoord: 0.5), canvas: canvas, metrics: metrics)
        #expect(frame.width == MapperGeometry.minimumControlSide && frame.height == MapperGeometry.minimumControlSide)
        #expect(abs(frame.midX - 800) < 0.01 && abs(frame.midY - 450) < 0.01)
    }

    @Test("A window shape different from the picture's keeps controls on the picture")
    func letterboxed() {
        // A 16:9 picture shown in a 2000 x 900 window: the horizontal unit scale stretches positions.
        let wide = ScreenMetrics(width: 2000, height: 900, renderSize: CGSize(width: 1600, height: 900))
        let frame = MapperGeometry.frame(of: KeyModelTransform(size: 5, xCoord: 0.5, yCoord: 0.5), canvas: CGSize(width: 2000, height: 900), metrics: wide)
        #expect(abs(frame.midX - 1000) < 0.01)
        #expect(abs(frame.width - 80 * (2000.0 / 1600)) < 0.01)
    }

    @Test("A click becomes a fraction of the canvas, never outside it")
    func relative() {
        #expect(MapperGeometry.relative(CGPoint(x: 800, y: 450), in: canvas) == CGPoint(x: 0.5, y: 0.5))
        #expect(MapperGeometry.relative(CGPoint(x: -50, y: 2000), in: canvas) == CGPoint(x: 0, y: 1))
        #expect(MapperGeometry.relative(CGPoint(x: 5, y: 5), in: .zero) == CGPoint(x: 0.5, y: 0.5))
    }

    @Test("The picker opens on the click and is kept inside the canvas")
    func popover() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let size = CGSize(width: 250, height: 220)
        let middle = MapperGeometry.popoverFrame(size: size, anchor: CGPoint(x: 800, y: 450), in: bounds)
        #expect(middle == CGRect(x: 675, y: 340, width: 250, height: 220))
        let corner = MapperGeometry.popoverFrame(size: size, anchor: CGPoint(x: 1590, y: 895), in: bounds)
        #expect(corner.maxX <= 1600 - 8 && corner.maxY <= 900 - 8 && corner.minX >= 8)
        let tiny = MapperGeometry.popoverFrame(size: size, anchor: CGPoint(x: 10, y: 10), in: CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(tiny.minX >= 0 && tiny.minY >= 0)
    }

    @Test("The panel sits below the control, above it when there is no room, never on the control or the toolbar")
    func inspector() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let size = CGSize(width: 320, height: 160)
        let toolbar = CGRect(x: 400, y: 12, width: 800, height: 48)
        let middle = CGRect(x: 760, y: 400, width: 80, height: 80)
        let below = MapperGeometry.inspectorFrame(size: size, near: middle, in: bounds, keepClear: toolbar)
        #expect(below.minY >= middle.maxY && !below.intersects(toolbar))
        #expect(abs(below.midX - middle.midX) < 0.01)

        let bottom = CGRect(x: 760, y: 800, width: 80, height: 80)
        let above = MapperGeometry.inspectorFrame(size: size, near: bottom, in: bounds, keepClear: toolbar)
        #expect(above.maxY <= bottom.minY && !above.intersects(bottom))

        let corner = CGRect(x: 1540, y: 820, width: 60, height: 60)
        let beside = MapperGeometry.inspectorFrame(size: size, near: corner, in: bounds, keepClear: toolbar)
        #expect(!beside.intersects(corner) && bounds.contains(beside))

        // Under the toolbar: the panel must go elsewhere.
        let underToolbar = CGRect(x: 760, y: 30, width: 80, height: 80)
        let moved = MapperGeometry.inspectorFrame(size: size, near: underToolbar, in: bounds, keepClear: toolbar)
        #expect(!moved.intersects(toolbar) && !moved.intersects(underToolbar))
    }

    @Test("A canvas smaller than the panel still gets a panel inside it")
    func smallCanvas() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        let frame = MapperGeometry.inspectorFrame(size: CGSize(width: 280, height: 150), near: CGRect(x: 120, y: 80, width: 60, height: 40), in: bounds)
        #expect(frame.minX >= 0 && frame.minY >= 0)
    }
}

@Suite("Mapper settings")
struct MapperSettingsTests {
    @Test("Defaults, and a saved value outside the range is brought inside it")
    func settings() throws {
        let defaults = MapperSettings()
        #expect(defaults.tintOpacity == 0.3 && defaults.showTips)
        let wild = try PropertyListDecoder().decode(MapperSettings.self, from: PropertyListEncoder().encode(["tintOpacity": 5.0]))
        #expect(wild.tintOpacity == MapperSettings.tintRange.upperBound)
        let low = try PropertyListDecoder().decode(MapperSettings.self, from: PropertyListEncoder().encode(["tintOpacity": -3.0]))
        #expect(low.tintOpacity == MapperSettings.tintRange.lowerBound)
        // An older settings file without the key keeps the defaults.
        #expect(try SettingsStore.decode(PropertyListEncoder().encode([String: String]())).mulg.mapper == defaults)
    }

    @Test("The mapper is a module that can be switched off")
    func module() {
        #expect(ModuleID.mapper.runsInGame && !ModuleID.mapper.isEssential)
        #expect(ModuleID.mapper.rawValue == "mapper")
    }
}
