import Foundation
final class CAMetalLayer {}
struct Settings { var targetRenderHeight: Int? = 1800; var mulg = Mulg() }
struct Mulg { var graphics = Graphics() }; struct Graphics { var metalFX = MetalFX() }; struct MetalFX { var enabled = true }
@MainActor final class Bridge {
    var binds = 0
    var bindGameLayer: ((CAMetalLayer) -> Void)? { { [self] _ in binds += 1 } }
}
@MainActor final class ModuleContext { var settings = Settings(); var bridge: Bridge? = Bridge() }
var surfaceUpdates = 0
@MainActor func mulg_graphics_update_render_surface(_ layer: CAMetalLayer, _ height: Int32) { surfaceUpdates += 1 }
@MainActor func mulg_graphics_set_main_layer(_ layer: CAMetalLayer) {}
@MainActor final class GraphicsModule {
    var closing = false, mainLayer: CAMetalLayer?, blockedLayer: CAMetalLayer?, blocker: Int?
    var metalFXEnabled = true, coreOnly = false, recoverableBlocker = false, starts = 0
    static func renderSurfaceHeight(_ settings: Settings) -> Int32 { Int32(settings.targetRenderHeight ?? 0) }
    func applyForcedResolution(_ settings: Settings) {}
    func writeRenderReport(layer: CAMetalLayer, context: ModuleContext) {}
    func startUpscaling(context: ModuleContext) { starts += 1 }
    func stopUpscaling() {}
    func restoreDisplaySync(_ context: ModuleContext) {}
    func updateDisplaySync(_ context: ModuleContext) {}
    func applyConfig(_ settings: Settings) {}
    // __PRODUCTION__
}
Task { @MainActor in
    let module = GraphicsModule(), context = ModuleContext(), layer = CAMetalLayer()
    module.closing = true
    module.mainLayerChanged(to: layer, context: context)
    assert(surfaceUpdates == 0 && context.bridge!.binds == 0 && module.starts == 0 && module.mainLayer == nil,
        "A queued surface signal must not resize or bind a closing renderer")
    module.closing = false
    module.mainLayerChanged(to: layer, context: context)
    assert(surfaceUpdates == 1 && context.bridge!.binds == 1 && module.starts == 1)
    print("PASS: queued surface changes stop at shutdown while normal surface binding works")
    exit(0)
}
dispatchMain()
