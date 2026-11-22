#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

/// Captures only the selected game's window for automatic tracking or a manual override.
/// It never reads another app, captures audio, or changes a game's drawable/framebuffer flags.
@MainActor
final class GameHUDCapture {
    private var capturing = false
    /// The game window as ScreenCaptureKit last listed it. Listing every window on screen is the
    /// costly step, so it is repeated only for another window or a new size.
    private var cachedWindow: SCWindow?

    /// macOS shows its Screen Recording dialog on every request until it is allowed, so a declined
    /// game was asked again at every HUD check. Ask once per game, ever: the answer is the player's.
    static let askedKey = "io.mulg.screenRecordingAsked"
    static func requestOnce() -> Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: askedKey) else { return false }
        defaults.set(true, forKey: askedKey)
        return CGRequestScreenCaptureAccess()
    }

    func capture(window: NSWindow?, rect: CGRect, requestPermission: Bool,
                 completion: @escaping (Data?, Int, Int, String?) -> Void) {
        guard !capturing else { completion(nil, 0, 0, "A HUD capture is already in progress."); return }
        guard let window, let content = window.contentView, window.isVisible, !window.isMiniaturized,
              !window.inLiveResize, NSApplication.shared.isActive, window.isKeyWindow else {
            completion(nil, 0, 0, "Bring the game window to the front and finish resizing it."); return
        }
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.width > 0, rect.height > 0, rect.minX >= 0, rect.minY >= 0,
              rect.maxX <= 1.001, rect.maxY <= 1.001 else {
            completion(nil, 0, 0, "The game surface could not be located."); return
        }
        guard CGPreflightScreenCaptureAccess() || (requestPermission && Self.requestOnce()) else {
            completion(nil, 0, 0, "Screen Recording is not allowed for this game; Mulg asks only once. Allow it in System Settings, or switch HUD anchoring off on the game's Privacy page."); return
        }
        let number = window.windowNumber, frame = window.frame, contentBounds = content.bounds
        let contentScreen = window.convertToScreen(content.convert(content.bounds, to: nil))
        capturing = true
        Task { @MainActor [weak self, weak window] in
            defer { self?.capturing = false }
            do {
                let item: SCWindow
                if let cached = self?.cachedWindow, cached.windowID == CGWindowID(number),
                   abs(cached.frame.width - frame.width) < 2, abs(cached.frame.height - frame.height) < 2 {
                    item = cached
                } else {
                    let available = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    guard let found = available.windows.first(where: {
                        $0.windowID == CGWindowID(number) && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
                    }) else { self?.cachedWindow = nil; completion(nil, 0, 0, "The game window is not available for HUD capture."); return }
                    item = found
                    self?.cachedWindow = found
                }
                guard item.frame.width.isFinite, item.frame.height.isFinite,
                      item.frame.width > 0, item.frame.height > 0 else {
                    completion(nil, 0, 0, "The native game window has no usable capture size."); return
                }
                let filter = SCContentFilter(desktopIndependentWindow: item)
                let config = SCStreamConfiguration()
                config.showsCursor = false; config.capturesAudio = false
                config.ignoreShadowsSingleWindow = true
                // The composited window may be 4K/5K. Matching uses one bounded reference scale.
                let scale = min(1, 768 / max(1, item.frame.height), 4096 / max(1, item.frame.width))
                config.width = max(2, Int((item.frame.width * scale).rounded()))
                config.height = max(2, Int((item.frame.height * scale).rounded()))
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                guard let window, window.windowNumber == number, window.frame == frame,
                      window.contentView?.bounds == contentBounds, !window.inLiveResize,
                      window.isKeyWindow, NSApplication.shared.isActive else {
                    completion(nil, 0, 0, "The game geometry changed during capture. Try again after resizing."); return
                }
                // ScreenCaptureKit's independent-window content rect excludes the shadow.
                // Refuse an unexpected source rectangle rather than silently shifting anchors.
                let source = item.frame
                guard abs(source.width - frame.width) < 2, abs(source.height - frame.height) < 2 else {
                    completion(nil, 0, 0, "The native window capture geometry is uncertain."); return
                }
                let sx = CGFloat(image.width) / source.width, sy = CGFloat(image.height) / source.height
                let x = contentScreen.minX - frame.minX + rect.minX * contentScreen.width
                let y = frame.maxY - contentScreen.maxY + rect.minY * contentScreen.height
                let crop = CGRect(x: x * sx, y: y * sy,
                    width: rect.width * contentScreen.width * sx, height: rect.height * contentScreen.height * sy)
                guard crop.minX >= -1, crop.minY >= -1,
                      crop.maxX <= CGFloat(image.width) + 1, crop.maxY <= CGFloat(image.height) + 1,
                      let cropped = image.cropping(to: crop.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))) else {
                    completion(nil, 0, 0, "The captured game surface was incomplete."); return
                }
                // Raster conversion can decode/resample millions of pixels. Keep that CPU
                // work off the event/render thread; window checks and completion stay here.
                let pixels = await Task.detached(priority: .utility) { Self.grayPixels(cropped) }.value
                guard window.windowNumber == number, window.frame == frame,
                      window.contentView?.bounds == contentBounds, !window.inLiveResize,
                      window.isKeyWindow, NSApplication.shared.isActive else {
                    completion(nil, 0, 0, "The game geometry changed during conversion. Try again after resizing."); return
                }
                if let (bytes, width, height) = pixels { completion(bytes, width, height, nil) }
                else { completion(nil, 0, 0, "HUD pixel conversion failed.") }
            } catch {
                self?.cachedWindow = nil  // the window may be gone; list again next time
                completion(nil, 0, 0, "HUD capture was unavailable. Check the game's Screen Recording permission.")
            }
        }
    }

    nonisolated private static func grayPixels(_ cropped: CGImage) -> (Data, Int, Int)? {
        autoreleasepool {
            let outputScale = min(1, 640 / CGFloat(cropped.height), 4096 / CGFloat(cropped.width))
            let width = max(2, Int((CGFloat(cropped.width) * outputScale).rounded()))
            let height = max(2, Int((CGFloat(cropped.height) * outputScale).rounded()))
            var bytes = Data(count: width * height)
            let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                context.interpolationQuality = .high
                // Preserve top-left raster coordinates and the existing matching scale.
                context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            return ok ? (bytes, width, height) : nil
        }
    }
}
#endif
