import Foundation
import Darwin

#if canImport(UIKit) && targetEnvironment(macCatalyst)
import UIKit
import WebKit
import MetalKit
import GameController
import Synchronization
import MulgContracts
import MulgControls
import MulgControlsHooks
import MulgEngine
import MulgEngineHooks
import MulgIntegrationsHooks
import Security
import MulgRuntime
import os

private let storageFixtureProcessHome = ProcessInfo.processInfo.environment["HOME"]

/// A delayed server acknowledgement fixture. It never contacts a real game service.
final class CloudFixture: URLProtocol, @unchecked Sendable {
    private let stopped = Mutex(false)
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "cloud.mulg-probe.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            guard !stopped.withLock({ $0 }), let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{\"accepted\":true}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { stopped.withLock { $0 = true } }
}

@MainActor
final class ProbeMetalView: MTKView {
    var touchesReceived = 0
    var simultaneousContacts = 0
    struct Sample { let phase: UITouch.Phase; let point: CGPoint; let ticks: UInt64 }
    var touchSamples: [ObjectIdentifier: [Sample]] = [:]
    private func record(_ touches: Set<UITouch>) {
        for touch in touches {
            touchSamples[ObjectIdentifier(touch), default: []].append(
                Sample(phase: touch.phase, point: touch.location(in: self), ticks: mach_absolute_time()))
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { record(touches) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { record(touches) }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        record(touches)
        touchesReceived += touches.count
        simultaneousContacts = max(simultaneousContacts, touches.count)
    }
}

@MainActor
final class ProbeRenderer: NSObject, @preconcurrency MTKViewDelegate {
    let queue: any MTLCommandQueue
    var frames = 0
    var resizeCallbacks = 0
    init(queue: any MTLCommandQueue) { self.queue = queue }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { resizeCallbacks += 1 }
    func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let buffer = frames.isMultiple(of: 2) ? queue.makeCommandBuffer()
                : queue.makeCommandBuffer(descriptor: MTLCommandBufferDescriptor()),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
        frames += 1
    }
}

@MainActor @objc(MulgRuntimeProbeDelegate)
final class ProbeDelegate: NSObject, UIApplicationDelegate {
    var window: UIWindow?
    private var renderer: ProbeRenderer?
    private var metalView: ProbeMetalView?
    private var presented = 0
    private var deliverySamples = 0
    private var lastProcessingTicks: UInt64 = 0
    private var backgroundTasksStarted = 0
    private var trackedBackgroundWork = false
    private var acknowledged = false
    private var sawBackground = false
    private var sawMemoryWarning = false
    private var sawWrapperMemoryPressure = false
    private var protectedCredentialRoundTrip = false
    private var sessionMutationBlocked = false
    private var smallerViewportSelected = false
    private var deviceScreenResize = false
    private var deviceRefreshReported = false
    private var nativeWebPointer = false
    private var desktopMouseStartup = false
    private var firstTurnMovementRetained = false
    private var centeredJoystickDelivered = false
    private var firstMoveLatencyMs: Double = -1
    private var nativePCValues = false
    private var earlyControllerVisible = false
    private var systemControllerConnected = false

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if let controls = MulgRuntime.shared.host?.module(.controls) as? ControlsModule,
           let native = controls.nativeController {
            earlyControllerVisible = GCController.controllers().contains { $0 === native }
        }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            finish(error: "No Metal device or command queue"); return false
        }
        let controller = UIViewController()
        let view = ProbeMetalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), device: device)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.clearColor = MTLClearColor(red: 0.1, green: 0.35, blue: 0.6, alpha: 1)
        view.preferredFramesPerSecond = 60
        let renderer = ProbeRenderer(queue: queue)
        self.renderer = renderer
        view.delegate = renderer
        metalView = view
        controller.view = view
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        guard let host = MulgRuntime.shared.host else { finish(error: "Injected runtime did not start"); return false }
        if ProcessInfo.processInfo.environment["MULG_PROBE_TOUCH_CONTROLS"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard let controls = host.module(.controls) as? ControlsModule, let router = controls.router else { exit(1) }
                let measured = ScreenMetrics(bounds: GameViewport.shared.bounds)
                let center = CGPoint(x: measured.width * 0.16 + 7, y: measured.height * 0.77 - 3)
                let radius: CGFloat = 40
                let calibrated = controls.calibrateMovement(center: center,
                    edge: CGPoint(x: center.x + radius, y: center.y), metrics: measured)
                let stored = KeymapStore(paths: host.context.paths, bundleIdentifier: host.context.bundleIdentifier).loadTouchDefault()
                let persisted = stored.keymap.joystickModel.first(where: { $0.upKeyCode == 26 })?.calibration != nil
                var preciseDirections = true
                for (codes, vector) in [
                    ([UInt16(0x0D)], CGPoint(x: 0, y: -1)), ([UInt16(0x01)], CGPoint(x: 0, y: 1)),
                    ([UInt16(0x00)], CGPoint(x: -1, y: 0)), ([UInt16(0x02)], CGPoint(x: 1, y: 0)),
                    ([UInt16(0x0D), 0x00], CGPoint(x: -1, y: -1)),
                    ([UInt16(0x0D), 0x02], CGPoint(x: 1, y: -1)),
                    ([UInt16(0x01), 0x00], CGPoint(x: -1, y: 1)),
                    ([UInt16(0x01), 0x02], CGPoint(x: 1, y: 1))
                ] {
                    for code in codes { _ = router.key(code: code, pressed: true, isRepeat: false, flags: 0) }
                    try? await Task.sleep(for: .milliseconds(80))
                    let contact = view.touchSamples.values.first { samples in
                        guard let start = samples.first, let last = samples.last else { return false }
                        return start.phase == .began && last.phase == .moved
                            && hypot(start.point.x - center.x, start.point.y - center.y) < 0.01
                    }
                    if let last = contact?.last {
                        let length = hypot(vector.x, vector.y)
                        preciseDirections = preciseDirections
                            && abs(last.point.x - center.x - radius * vector.x / length) < 0.01
                            && abs(last.point.y - center.y - radius * vector.y / length) < 0.01
                    } else { preciseDirections = false }
                    for code in codes { _ = router.key(code: code, pressed: false, isRepeat: false, flags: 0) }
                    try? await Task.sleep(for: .milliseconds(35))
                }
                let baseline = view.touchesReceived
                let previousIdentities = Set(view.touchSamples.keys)
                let key = router.key(code: 0x0D, pressed: true, isRepeat: false, flags: 0)
                try? await Task.sleep(for: .milliseconds(80))
                let movement = view.touchesReceived > baseline
                    && view.touchSamples.values.contains { $0.contains { $0.phase == .moved } }
                let attackBaseline = view.touchesReceived
                let mouse = router.mouseButton(0, pressed: true)
                try? await Task.sleep(for: .milliseconds(30))
                let attack = view.touchesReceived > attackBaseline
                let contactCount = view.touchesReceived
                let identities = Set(view.touchSamples.keys)
                let heldIdentities = identities.subtracting(previousIdentities)
                var heldAcrossResizes = true, screenFollowsResizes = true
                var resizeDetails: [[String: Any]] = []
                for size in [CGSize(width: 1376, height: 1032), CGSize(width: 1920, height: 1080),
                             CGSize(width: 3440, height: 1440), CGSize(width: 720, height: 960), CGSize(width: 900, height: 700)] {
                    window.bounds = CGRect(origin: .zero, size: size)
                    view.frame = window.bounds
                    window.setNeedsLayout(); window.layoutIfNeeded()
                    view.setNeedsLayout(); view.layoutIfNeeded()
                    GameViewport.shared.laidOut(view)
                    try? await Task.sleep(for: .milliseconds(35))
                    resizeDetails.append(["width": size.width, "height": size.height, "began": view.touchesReceived, "live": mulg_touch_live_count(), "phases": view.touchSamples.values.map { $0.last?.phase.rawValue ?? -1 }])
                    heldAcrossResizes = heldAcrossResizes && view.touchesReceived == contactCount
                        && Set(view.touchSamples.keys) == identities && mulg_touch_live_count() == 2
                        && heldIdentities.allSatisfy { view.touchSamples[$0]?.last?.phase == .moved }
                    screenFollowsResizes = screenFollowsResizes && window.screen.bounds.size == size
                        && window.screen.nativeBounds.size == CGSize(width: size.width * 2, height: size.height * 2)
                }
                _ = router.key(code: 0x0D, pressed: false, isRepeat: false, flags: 0)
                _ = router.mouseButton(0, pressed: false)
                try? await Task.sleep(for: .milliseconds(30))
                let checks = ["touchMode": host.context.settings.mulg.controls.playMode == .touch,
                    "calibrationApplied": calibrated, "calibrationPersisted": persisted,
                    "eightPreciseDirections": preciseDirections,
                    "noVirtualController": controls.nativeController == nil,
                    "touchProfile": controls.keymap?.hasTouchControls == true,
                    "iPadReference": controls.keymap?.mulgAspectRatio == 4.0 / 3,
                    "freeWindowShape": controls.keymap?.mulgLockAspectRatio == false,
                    "heldTouchesSurviveResizes": heldAcrossResizes,
                    "screenFollowsResizes": screenFollowsResizes,
                    "cameraMode": router.mode == .camera,
                    "keyboardMovementDelivered": key && movement,
                    "mouseAttackDelivered": mouse && attack,
                    "contactsReleased": mulg_touch_live_count() == 0]
                let result: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks,
                    "profile": controls.keymapFile?.lastPathComponent ?? "", "initialContacts": contactCount, "resizes": resizeDetails, "remainingContacts": mulg_touch_live_count()]
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
                }
                exit(checks.values.allSatisfy { $0 } ? 0 : 1)
            }
            return true
        }
        if ProcessInfo.processInfo.environment["MULG_PROBE_SYSTEM_CONTROLLER"] == "1" {
            Task { @MainActor in
                let configuration = GCVirtualController.Configuration()
                configuration.isHidden = true
                configuration.elements = [GCInputLeftThumbstick, GCInputRightThumbstick,
                    GCInputButtonA, GCInputButtonB, GCInputButtonX, GCInputButtonY,
                    GCInputLeftShoulder, GCInputRightShoulder, GCInputLeftTrigger, GCInputRightTrigger,
                    GCInputDirectionPad, GCInputButtonMenu, GCInputButtonOptions,
                    GCInputLeftThumbstickButton, GCInputRightThumbstickButton]
                let device = GCVirtualController(configuration: configuration)
                var result: [String: Any] = [:]
                do {
                    try await device.connect()
                    try? await Task.sleep(for: .milliseconds(150))
                    if let native = device.controller, let pad = native.extendedGamepad {
                                                device.setValue(1, forButtonElement: GCInputButtonB)
                        device.setValue(1, forButtonElement: GCInputButtonMenu)
                        device.setValue(1, forButtonElement: GCInputButtonOptions)
                        device.setValue(1, forButtonElement: GCInputLeftThumbstickButton)
                        device.setPosition(CGPoint(x: 1, y: 0), forDirectionPadElement: GCInputDirectionPad)
                        device.setPosition(CGPoint(x: 0, y: 1), forDirectionPadElement: GCInputLeftThumbstick)
                        try? await Task.sleep(for: .milliseconds(150))
                        result = ["passed": pad.buttonB.isPressed && pad.leftThumbstick.yAxis.value == 1,
                            "vendor": native.vendorName ?? "", "category": native.productCategory,
                            "snapshot": native.isSnapshot,
                            "connected": GCController.controllers().contains { $0 === native },
                                                        "attack": pad.buttonB.value, "movement": pad.leftThumbstick.yAxis.value,
                            "menu": pad.buttonMenu.value, "options": pad.buttonOptions?.value ?? -1,
                            "leftClick": pad.leftThumbstickButton?.value ?? -1,
                            "dpadRight": pad.dpad.right.value]
                    } else { result = ["passed": false, "error": "No connected extended gamepad"] }
                } catch { result = ["passed": false, "error": String(describing: error)] }
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
                }
                device.disconnect()
                exit(result["passed"] as? Bool == true ? 0 : 1)
            }
            return true
        }
        if let mode = ProcessInfo.processInfo.environment["MULG_PROBE_STORAGE_MODE"] {
            Task { @MainActor in await runStoragePersistenceFixture(mode: mode) }
            return true
        }
        if ProcessInfo.processInfo.environment["MULG_PROBE_POINTER_UI"] == "1" {
            // Interactive fixture for native AppKit-to-WebKit pointer delivery. This local
            // range control has no network request, login or verification challenge.
            let web = WKWebView(frame: view.bounds)
            web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            web.loadHTMLString("<html><body style='background:white;padding:60px;font:24px sans-serif'><h2>Mulg mouse drag test</h2><p>Drag the ordinary slider from left to right.</p><input aria-label='Mouse drag test' type='range' min='0' max='100' value='0' style='width:500px;height:60px'></body></html>", baseURL: nil)
            view.addSubview(web)
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { exit(0) }
            return true
        }
        host.context.events.subscribe(FramePresented.self) { [weak self] _ in self?.presented += 1 }
        host.context.events.subscribe(MemoryPressure.self) { [weak self] _ in self?.sawWrapperMemoryPressure = true }
        host.context.events.publish(FrameReportingRequested(requester: .diagnostics, enabled: true))
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if let controls = host.module(.controls) as? ControlsModule, let router = controls.router {
                // Exercise the actual module's router-before-keymap startup order.
                desktopMouseStartup = router.mode == .camera
                    && router.mouseMoved(dx: 20, dy: -10)
                    && router.mouseButton(0, pressed: true)
                    && router.mouseButton(0, pressed: false)
                if let native = controls.nativeController, let pad = native.extendedGamepad {
                    let moved = router.key(code: 0x0D, pressed: true, isRepeat: false, flags: 0)
                    try? await Task.sleep(for: .milliseconds(30))
                    let movement = pad.leftThumbstick.yAxis.value == 1
                    systemControllerConnected = !native.isSnapshot
                        && native.vendorName != nil && GCController.controllers().contains { $0 === native }
                    _ = router.key(code: 0x0D, pressed: false, isRepeat: false, flags: 0)
                    _ = router.key(code: 0x0F, pressed: true, isRepeat: false, flags: 0) // R
                    _ = router.key(code: 0x0F, pressed: false, isRepeat: false, flags: 0)
                    _ = router.mouseButton(0, pressed: true)
                    try? await Task.sleep(for: .milliseconds(30))
                    let aimed = pad.leftTrigger.isPressed && pad.rightTrigger.isPressed && !pad.buttonB.isPressed
                    _ = router.mouseButton(0, pressed: false)
                    _ = router.resumeGameplay()
                    try? await Task.sleep(for: .milliseconds(30))
                    nativePCValues = moved && movement && aimed && !pad.leftTrigger.isPressed
                        && !pad.rightTrigger.isPressed && pad.leftThumbstick.yAxis.value == 0
                }
            }
            let followsWindow = ResolutionMode(setting: host.context.settings.resolution) == .matchDevice
            let originalBounds = window.bounds
            if followsWindow {
                // Exercise UIKit layout, viewport publication and the production UIScreen hooks
                // after the initial key window has already activated the runtime.
                let scene = window.windowScene
                let initialWindowResizable = (scene?.sizeRestrictions?.maximumSize.width ?? 0) >= 16_384
                let resized = CGSize(width: 720, height: 480)
                window.bounds = CGRect(origin: .zero, size: resized)
                window.setNeedsLayout(); window.layoutIfNeeded()
                GameViewport.shared.laidOut(window)
                deviceScreenResize = initialWindowResizable && window.screen.bounds.size == resized
                    && window.screen.nativeBounds.size == CGSize(width: resized.width * 2, height: resized.height * 2)
                window.bounds = originalBounds
                window.setNeedsLayout(); window.layoutIfNeeded()
                GameViewport.shared.laidOut(window)
            } else { deviceScreenResize = true }
            deviceRefreshReported = !host.context.settings.mulg.display.reportProMotion
                || window.screen.maximumFramesPerSecond == 120
            // A plain web view exercises production interface detection; no authentication
            // service or challenge is contacted. Original mouse events must reach UIKit.
            if let controls = host.module(.controls) as? ControlsModule, let router = controls.router {
                let before = router.mode
                let web = WKWebView(frame: CGRect(x: 80, y: 80, width: 400, height: 200))
                web.isHidden = true
                view.addSubview(web)
                try? await Task.sleep(for: .milliseconds(350))
                let hiddenIgnored = !router.nativeInterfaceActive
                web.isHidden = false
                try? await Task.sleep(for: .milliseconds(350))
                let shown = router.nativeInterfaceActive
                let down = !router.mouseButton(0, pressed: true)
                let drag = !router.mouseMoved(dx: 150, dy: 0)
                web.removeFromSuperview()
                try? await Task.sleep(for: .milliseconds(350))
                let owned = router.nativeInterfaceActive
                let up = !router.mouseButton(0, pressed: false)
                nativeWebPointer = hiddenIgnored && shown && down && drag && owned && up
                    && !router.nativeInterfaceActive && router.mode == before
            }
            checkCredentials(host: host)
            do {
                let lease = try GameSessionLease(bundleIdentifier: host.context.bundleIdentifier, paths: host.context.paths)
                withExtendedLifetime(lease) {}
            } catch GameSessionLease.Failure.busy { sessionMutationBlocked = true }
            catch { sessionMutationBlocked = false }
            // An active gameplay surface stays selected; after it stops rendering, a smaller
            // replacement wins. Queued old activity must not revive the paused loading view.
            let replacement = ProbeMetalView(frame: CGRect(x: 40, y: 30, width: 320, height: 240), device: device)
            replacement.isPaused = true
            view.addSubview(replacement)
            if let originalLayer = view.layer as? CAMetalLayer, let replacementLayer = replacement.layer as? CAMetalLayer {
                _ = GameViewport.shared.drawing(originalLayer)
                let activeKept = GameViewport.shared.drawing([(originalLayer, CACurrentMediaTime()),
                    (replacementLayer, CACurrentMediaTime())]) === originalLayer
                view.isPaused = true
                try? await Task.sleep(for: .milliseconds(2200))
                let selected = GameViewport.shared.drawing(replacementLayer) === replacementLayer
                let staleIgnored = GameViewport.shared.drawing([(originalLayer, CACurrentMediaTime() - 3)]) === replacementLayer
                smallerViewportSelected = activeKept && selected && staleIgnored
                    && GameViewport.shared.bounds.size == replacement.bounds.size
                replacement.removeFromSuperview()
                view.isPaused = false
                _ = GameViewport.shared.drawing(originalLayer)
            }
            // Controls installs its handler on activation, so attach the probe after that.
            mulg_touch_set_delivery_handler { [weak self] arrival, delivered in
                MainActor.assumeIsolated {
                    self?.deliverySamples += 1
                    self?.lastProcessingTicks = delivered >= arrival ? delivered - arrival : UInt64.max
                }
            }
            let injector = SystemTouchInjector()
            // Both movements arrive before the run-loop source can deliver began.
            // The native injector must preserve the center and then the latest position.
            var centered: Int?
            let center = CGPoint(x: 120, y: 160), final = CGPoint(x: 160, y: 130)
            let arrival = mach_absolute_time()
            injector.touch(&centered, at: center, phase: .began)
            injector.touch(&centered, at: CGPoint(x: 140, y: 140), phase: .moved)
            injector.touch(&centered, at: final, phase: .moved)
            try? await Task.sleep(for: .milliseconds(30))
            let samples = view.touchSamples.values.first { $0.first?.point == center && $0.first?.phase == .began }
            firstTurnMovementRetained = samples?.contains { $0.phase == .moved && $0.point == final } == true
            centeredJoystickDelivered = samples?.first?.point == center && firstTurnMovementRetained
            if let moved = samples?.first(where: { $0.phase == .moved && $0.point == final }) {
                var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
                firstMoveLatencyMs = Double(moved.ticks - arrival) * Double(info.numer) / Double(info.denom) / 1e6
            }
            injector.touch(&centered, at: final, phase: .ended)
            try? await Task.sleep(for: .milliseconds(20))
            var touch: Int?
            mulg_touch_set_input_timestamp(mach_absolute_time())
            injector.touch(&touch, at: CGPoint(x: 100, y: 100), phase: .began)
            mulg_touch_set_input_timestamp(mach_absolute_time())
            injector.touch(&touch, at: CGPoint(x: 100, y: 100), phase: .ended)
            var firstContact: Int?, secondContact: Int?
            injector.touch(&firstContact, at: CGPoint(x: 200, y: 100), phase: .began)
            injector.touch(&secondContact, at: CGPoint(x: 300, y: 100), phase: .began)
            injector.touch(&firstContact, at: CGPoint(x: 200, y: 100), phase: .ended)
            injector.touch(&secondContact, at: CGPoint(x: 300, y: 100), phase: .ended)
            mulg_touch_set_input_timestamp(0)
            view.drawableSize = CGSize(width: 640, height: 480)
            NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: application)
            application.delegate?.applicationDidReceiveMemoryWarning?(application)
            try? await Task.sleep(for: .seconds(1))
            var settings = EngineSettings()
            settings.shutdownGraceSeconds = 1
            settings.shutdownDeadlineSeconds = 6
            host.context.events.publish(GameClosing())
            GameShutdown.run(lifecycle: GameLifecycle(), settings: settings,
                             logger: Logger(subsystem: "io.mulg.RuntimeProbe", category: "engine")) { [weak self] in
                host.context.events.publish(GameShutdownFinished())
                self?.finish(error: nil)
            }
        }
        return true
    }

    /// Run twice in a real sandbox: write an ordinary preference and external asset, then
    /// restart and read both. A successful synchronize alone does not prove persistence.
    private func runStoragePersistenceFixture(mode: String) async {
        do {
            let token = ProcessInfo.processInfo.environment["MULG_PROBE_STORAGE_TOKEN"] ?? "storage-restart-fixture"
            guard let root = Bundle.main.object(forInfoDictionaryKey: "MulgGameDataRoot") as? String
            else { throw CocoaError(.fileReadCorruptFile) }
            let expectedHome = URL(fileURLWithPath: root).appendingPathComponent("Data").path
            let actualHome = NSHomeDirectory()
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true)
            let asset = documents.appendingPathComponent("mulg-storage-fixture.bin")
            let defaults = UserDefaults.standard
            if mode == "write" {
                defaults.set(token, forKey: "MulgStorageRestartFixture")
                try Data(token.utf8).write(to: asset, options: .atomic)
            }
            let synced = defaults.synchronize()
            let preferences = ContainerPaths.current().gameContainer(for: "io.mulg.RuntimeProbe")
                .appendingPathComponent("Data/Library/Preferences/io.mulg.RuntimeProbe.plist")
            let nativeAtomic = preferences.deletingLastPathComponent().appendingPathComponent("MulgNativeAtomicFixture.bin")
            try Data(token.utf8).write(to: nativeAtomic, options: .atomic)
            let nativeAtomicPassed = try Data(contentsOf: nativeAtomic) == Data(token.utf8)
            try FileManager.default.removeItem(at: nativeAtomic)
            // cfprefsd acknowledges the cache before its disk transaction completes.
            // Check the real native file after a bounded wait, then relaunch independently.
            for _ in 0..<200 {
                if let bytes = try? Data(contentsOf: preferences),
                   let stored = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
                   stored["MulgStorageRestartFixture"] as? String == token { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let bytes = try Data(contentsOf: preferences)
            let persisted = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any]
            let checks = ["nativeProcessHome": ProcessInfo.processInfo.environment["HOME"] == storageFixtureProcessHome,
                "nativeAtomicWrites": nativeAtomicPassed,
                "gameHomeExternal": actualHome == expectedHome,
                "gameCHomeExternal": getenv("HOME").map { String(cString: $0) } == expectedHome,
                "gameDocumentsExternal": documents.path == expectedHome + "/Documents",
                "gameAssetReused": try Data(contentsOf: asset) == Data(token.utf8),
                "preferencesAccessible": synced,
                "preferencesPersistedNatively": persisted?["MulgStorageRestartFixture"] as? String == token,
                "preferenceReadAfterRelaunch": defaults.string(forKey: "MulgStorageRestartFixture") == token]
            let report: [String: Any] = ["mode": mode, "passed": checks.values.allSatisfy { $0 }, "checks": checks]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
            exit(checks.values.allSatisfy { $0 } ? 0 : 1)
        } catch {
            FileHandle.standardError.write(Data("Storage restart fixture failed: \(error)\n".utf8))
            exit(1)
        }
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) { sawMemoryWarning = true }
    func applicationDidEnterBackground(_ application: UIApplication) {
        sawBackground = true
        backgroundTasksStarted += 1
        let task = application.beginBackgroundTask(withName: "Probe cloud acknowledgement", expirationHandler: nil)
        trackedBackgroundWork = mulg_engine_background_task_count() > 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudFixture.self]
        let session = URLSession(configuration: configuration)
        Task { @MainActor in
            defer { application.endBackgroundTask(task); session.invalidateAndCancel() }
            do {
                let (data, response) = try await session.data(from: URL(string: "https://cloud.mulg-probe.invalid/progress")!)
                acknowledged = (response as? HTTPURLResponse)?.statusCode == 200
                    && String(decoding: data, as: UTF8.self) == "{\"accepted\":true}"
            } catch { acknowledged = false }
        }
    }

    private func checkCredentials(host: ModuleHost) {
        let secret = Data("mulg-probe-token-\(UUID().uuidString)".utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: "io.mulg.probe", kSecAttrAccount as String: UUID().uuidString]
        let before = mulg_keychain_answered_count()
        guard SecItemAdd(query.merging([kSecValueData as String: secret]) { _, new in new } as CFDictionary, nil) == errSecSuccess else { return }
        defer { SecItemDelete(query as CFDictionary) }
        var returned: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { _, new in new } as CFDictionary, &returned)
        let file = host.context.paths.mulgChainDatabase(for: host.context.bundleIdentifier)
        let protected = (try? Data(contentsOf: file)).map { $0.range(of: secret) == nil } ?? false
        protectedCredentialRoundTrip = status == errSecSuccess && returned as? Data == secret
            && mulg_keychain_answered_count() >= before + 2 && FileManager.default.fileExists(atPath: file.path) && protected
    }

    private func finish(error: String?) {
        let host = MulgRuntime.shared.host
        host?.context.hooks.refreshInstallationReports()
        let checks: [String: Bool] = [
            "nativeWebPointerRouting": nativeWebPointer,
            "desktopMouseStartup": desktopMouseStartup,
            "earlyNativeControllerVisible": earlyControllerVisible,
            "nativePCControllerValues": nativePCValues,
            "systemConnectedController": systemControllerConnected,
            "firstTurnMovementRetained": firstTurnMovementRetained,
            "centeredJoystickDelivered": centeredJoystickDelivered,
            "runtimeStarted": host != nil,
            "bridgeLoaded": host?.context.bridge != nil,
            "sessionMutationBlocked": sessionMutationBlocked,
            "touchABIAvailable": mulg_touch_is_available(),
            "smallerViewportSelected": smallerViewportSelected,
            "protectedCredentialRoundTrip": protectedCredentialRoundTrip,
            "metalFrames": (renderer?.frames ?? 0) >= 30,
            "presentationEvents": presented >= 10,
            "touchReachedView": (metalView?.touchesReceived ?? 0) > 0,
            "simultaneousContacts": (metalView?.simultaneousContacts ?? 0) >= 2,
            "actualTouchDelivery": deliverySamples >= 2 && lastProcessingTicks < UInt64.max,
            "resizeCallback": (renderer?.resizeCallbacks ?? 0) > 0,
            "devicePresetResize": deviceScreenResize,
            "device120HzCapability": deviceRefreshReported,
            "memoryWarning": sawMemoryWarning,
            "wrapperMemoryPressure": sawWrapperMemoryPressure,
            "backgroundLifecycle": sawBackground,
            "backgroundTaskTracked": backgroundTasksStarted > 0 && trackedBackgroundWork,
            "delayedCloudFixtureAcknowledgedBeforeExit": acknowledged,
            "noHookOwnershipConflicts": host?.context.hooks.conflicts.isEmpty == true
        ]
        let result: [String: Any] = ["passed": error == nil && checks.values.allSatisfy { $0 },
            "checks": checks, "error": error ?? "", "runtimeVersion": MulgVersion.current,
            "runtimeProtocol": MulgVersion.runtimeProtocol, "frames": renderer?.frames ?? 0,
            "presentedFrames": presented, "deliverySamples": deliverySamples, "firstMoveLatencyMs": firstMoveLatencyMs,
            "system": ProcessInfo.processInfo.operatingSystemVersionString,
            "cloudFixture": "Delayed URLSession response only; no real game cloud sync is asserted"]
        do {
            guard CommandLine.arguments.count > 1 else { throw CocoaError(.fileNoSuchFile) }
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        } catch { exit(1) }
        exit(result["passed"] as? Bool == true ? 0 : 1)
    }
}

// Exercise the production startup path before UIApplicationMain, as injection does.
_ = storageFixtureProcessHome
mulgRuntimeStart()
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(ProbeDelegate.self))
#else
FileHandle.standardError.write(Data("Build MulgRuntimeProbe for ARM64 Mac Catalyst on macOS 27.\n".utf8))
exit(1)
#endif
