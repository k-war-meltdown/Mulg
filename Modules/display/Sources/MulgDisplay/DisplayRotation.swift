import Foundation
import MulgContracts
import MulgEngine

/// Rotating the game's display area (upstream `rotateView` and `RotateViewController`).
///
/// iOS decides an app's orientation from the view controller being presented full screen,
/// so a rotation briefly presents a controller that prefers the wanted orientation.
/// Changes from upstream:
/// - the saved rotation is applied when the first scene is active, instead of on a fixed
///   0.5 s timer that could fire before the game had a window (§16.2 E5);
/// - it presents from the top-most controller of the key window once, instead of from the
///   root of every window in every scene;
/// - the helper is dismissed as soon as it has appeared, not after a fixed second;
/// - choosing a rotation from the menu is saved, so it survives the next launch.
public enum DisplayRotation {
    /// Menu order and the `displayRotation` setting: 0 = landscape left, 1 = portrait,
    /// 2 = landscape right, 3 = portrait upside down.
    public static let titles = [
        "Landscape Left (0°)", "Portrait (90°)", "Landscape Right (180°)", "Portrait Upside Down (270°)"
    ]

    public static func normalised(_ index: Int) -> Int {
        ((index % titles.count) + titles.count) % titles.count
    }

    public static func menuCommands() -> [MenuCommand] {
        titles.enumerated().map { index, title in
            MenuCommand(id: "display.rotate.\(index)", title: title, key: "\(index + 1)",
                        modifiers: [.command, .shift], section: "display", submenu: "Rotate display area")
        }
    }
}

#if canImport(UIKit) && !os(watchOS)
import UIKit

extension DisplayRotation {
    static let orientations: [UIInterfaceOrientation] = [.landscapeLeft, .portrait, .landscapeRight, .portraitUpsideDown]
    @MainActor private static var latestRequest = UUID()

    /// Rotates to `index`; retries for a moment when the game has no window yet.
    @MainActor
    public static func apply(_ index: Int, attempts: Int = 20) {
        let request = UUID()
        latestRequest = request
        apply(index, attempts: attempts, request: request)
    }

    @MainActor
    private static func apply(_ index: Int, attempts: Int, request: UUID) {
        guard request == latestRequest else { return }
        // UIKit rejects presentation while this controller is entering/leaving another
        // presentation. Preserve the current request and retry after the transition.
        guard let presenter = topViewController(), !presenter.isBeingPresented,
              !presenter.isBeingDismissed, presenter.transitionCoordinator == nil else {
            guard attempts > 0 else { return }
            Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                apply(index, attempts: attempts - 1, request: request)
            }
            return
        }
        let rotation = RotationViewController(orientation: orientations[normalised(index)])
        presenter.present(rotation, animated: false)
    }

    @MainActor
    static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first,
              var top = window.rootViewController, top.viewIfLoaded?.window != nil else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

/// Presented full screen for a moment so iOS adopts its preferred orientation.
final class RotationViewController: UIViewController {
    private let orientation: UIInterfaceOrientation

    init(orientation: UIInterfaceOrientation) {
        self.orientation = orientation
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { orientation }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The interface has taken the new orientation by now.
        presentingViewController?.dismiss(animated: false)
    }
}
#endif
