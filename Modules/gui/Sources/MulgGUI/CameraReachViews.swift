#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import MulgContracts
import SwiftUI

/// Camera reach in a game's Controls settings: the switch, how far, a preview of the result, the
/// ban warning, and what the running game reports.
struct CameraReachSection: View {
    @Binding var settings: CameraSettings
    let bundleIdentifier: String
    @Binding var warnings: [OnlineWarning.Feature]

    @State private var report: CameraReachReport?
    @State private var calibration: CameraCalibration?
    @State private var running = false

    private var enabled: Binding<Bool> {
        Binding(get: { settings.extendedReach }, set: { on in
            settings.extendedReach = on
            if on { warnings += OnlineWarning.pending([.cameraReach], bundleIdentifier: bundleIdentifier) }
        })
    }

    private var hotkey: String { Hotkey(settings.calibrateHotkey)?.description ?? settings.calibrateHotkey }
    /// Keys without ⌘ or ⌥, which belong to menu shortcuts and the cursor key.
    static let hotkeyChoices = ["shift+9", "shift+0", "control+9", "f9", "f10"]

    var body: some View {
        Section {
            Label {
                Text("May get your account banned. Camera reach changes the game's own memory. Online games such as Genshin Impact and Honkai: Star Rail forbid modifying the game and may detect it. Use it at your own risk, ideally on an account you can afford to lose.", bundle: .module)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.callout)
            .foregroundStyle(.orange)

            Toggle(isOn: enabled) {
                OptionLabel("Camera reach", .live, key: "mulg.camera.extendedReach", owner: .camera)
            }

            VStack(alignment: .leading, spacing: 10) {
                Slider(value: $settings.reach, in: CameraSettings.reachRange, step: 0.1) {
                    OptionLabel("Camera distance", .live, key: "mulg.camera.reach", owner: .camera)
                } minimumValueLabel: {
                    Text(verbatim: "1.1×").font(.caption)
                } maximumValueLabel: {
                    Text(verbatim: "3×").font(.caption)
                }
                Text(distanceDescription).font(.caption).foregroundStyle(.secondary)
                CameraReachPreview(reach: settings.reach)
                Text("The camera moves back along its own angle, so the picture is not stretched: the character gets smaller and you see more around them. Above about 2× the camera can pass through walls and ceilings, and far areas may appear before the game has loaded them.", bundle: .module)
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!settings.extendedReach)

            Picker(selection: $settings.calibrateHotkey) {
                ForEach(Self.hotkeyChoices, id: \.self) { choice in
                    Text(verbatim: Hotkey(choice)?.description ?? choice).tag(choice)
                }
                if !Self.hotkeyChoices.contains(settings.calibrateHotkey) {
                    Text(verbatim: hotkey).tag(settings.calibrateHotkey)
                }
            } label: {
                OptionLabel("Calibration key (in the game)", .live, key: "mulg.camera.calibrateHotkey", owner: .camera)
            }
            if let calibration {
                LabeledContent(String(localized: "Calibrated", bundle: .module)) {
                    Text(verbatim: "\(calibration.gameVersion) · \(calibration.created.formatted(date: .abbreviated, time: .omitted)) · \(format(calibration.farthest)) → \(format(calibration.farthest * Float(settings.reach)))")
                }
                Button(String(localized: "Forget Calibration", bundle: .module), role: .destructive, action: forget)
                    .help(String(localized: "Deletes the saved calibration. A running game keeps its raised limit until it restarts; in the game, use Controls → Camera Reach → Forget Calibration instead.", bundle: .module))
            }
            if running, settings.extendedReach, let report {
                HStack(alignment: .top) {
                    Label(statusTitle(report.state), systemImage: statusSymbol(report.state))
                        .font(.caption).foregroundStyle(statusColor(report.state)).fixedSize()
                    Text(report.message).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } header: {
            Text("Camera reach", bundle: .module)
        } footer: {
            Text("Lets the camera zoom out farther than the game allows. To set it up, stand in the open world (not a loading screen or menu) and press \(hotkey) once. Mulg then zooms the camera out and in by itself for about a minute; keep still. It never starts by itself; press \(hotkey) twice quickly to cancel. Calibration briefly needs a few hundred MB of memory.", bundle: .module)
        }
        .task(id: bundleIdentifier) {
            while !Task.isCancelled {
                refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private var distanceDescription: String {
        let percent = Int(((settings.reach - 1) * 100).rounded())
        return String(localized: "\(String(format: "%.1f", settings.reach))× the game's farthest zoom (\(percent) % farther)", bundle: .module)
    }

    private func format(_ value: Float) -> String {
        String(format: value < 10 ? "%.2f" : "%.1f", value)
    }

    private func refresh() {
        let paths = ContainerPaths.current()
        calibration = CameraCalibration.load(from: paths.cameraCalibrationFile(for: bundleIdentifier))
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).filter { !$0.isTerminated }
        running = !apps.isEmpty
        let file = paths.diagnosticsDirectory(for: bundleIdentifier).appendingPathComponent(CameraReachReport.fileName)
        guard running, let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65_536,
              let data = try? Data(contentsOf: file),
              let value = try? JSONDecoder().decode(CameraReachReport.self, from: data),
              apps.contains(where: { $0.processIdentifier == value.processIdentifier }) else {
            report = nil
            return
        }
        report = value
    }

    private func forget() {
        try? FileManager.default.removeItem(at: ContainerPaths.current().cameraCalibrationFile(for: bundleIdentifier))
        calibration = nil
    }

    private func statusTitle(_ state: CameraReachReport.State) -> String {
        switch state {
        case .off: String(localized: "Off", bundle: .module)
        case .notCalibrated: String(localized: "Not calibrated", bundle: .module)
        case .calibrating: String(localized: "Calibrating", bundle: .module)
        case .searching: String(localized: "Searching", bundle: .module)
        case .applied: String(localized: "Active", bundle: .module)
        case .notFound: String(localized: "Calibrate again", bundle: .module)
        case .unsupported: String(localized: "Not possible", bundle: .module)
        }
    }

    private func statusSymbol(_ state: CameraReachReport.State) -> String {
        switch state {
        case .applied: "checkmark.circle"
        case .notFound, .unsupported: "exclamationmark.triangle"
        case .searching, .calibrating: "clock"
        case .off, .notCalibrated: "minus.circle"
        }
    }

    private func statusColor(_ state: CameraReachReport.State) -> Color {
        [.notFound, .unsupported].contains(state) ? .orange : .secondary
    }
}

/// Two drawings of the same scene: the game's farthest camera and the one Camera reach allows.
struct CameraReachPreview: View {
    let reach: Double

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            panel(distance: 1, title: String(localized: "Game's farthest zoom", bundle: .module))
            panel(distance: reach, title: String(localized: "With Camera reach (\(String(format: "%.1f", reach))×)", bundle: .module))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Preview: the character appears smaller and more of the scene is visible with Camera reach.", bundle: .module))
    }

    private func panel(distance: Double, title: String) -> some View {
        VStack(spacing: 4) {
            Canvas { context, size in CameraReachScene.draw(in: context, size: size, reach: distance) }
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A small perspective drawing: a character on open ground among trees, seen by a camera that
/// pulls back along its own angle as `reach` grows.
enum CameraReachScene {
    private struct Tree { let x: Double; let z: Double; let height: Double }

    /// Fixed, so both panels and every redraw show the same scene.
    private static let trees: [Tree] = (0..<60).map { index in
        let column = Double(index % 10) - 4.5, row = Double(index / 10)
        let jitter = sin(Double(index) * 12.9898) * 0.9
        return Tree(x: column * 3.1 + jitter + (column >= 0 ? 1.2 : -1.2), z: row * 3.6 - 3 + jitter,
                    height: 2.6 + abs(cos(Double(index) * 4.1)) * 1.8)
    }

    static func draw(in context: GraphicsContext, size: CGSize, reach: Double) {
        // The game's farthest camera: 6 units behind the character, 2.6 up, looking at its chest.
        let distance = 6 * reach, height = 1 + 1.6 * reach
        let pitch = atan2(height - 1, distance)
        let focal = size.height * 1.15
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)

        func project(_ x: Double, _ y: Double, _ z: Double) -> (CGPoint, Double)? {
            let dy = y - height, dz = z + distance
            let depth = -dy * sin(pitch) + dz * cos(pitch)
            guard depth > 0.3 else { return nil }
            let up = dy * cos(pitch) + dz * sin(pitch)
            return (CGPoint(x: centre.x + focal * x / depth, y: centre.y - focal * up / depth), depth)
        }

        // Sky and ground meet at the horizon, which sits higher as the camera tilts down.
        let horizon = centre.y - focal * tan(pitch)
        context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: max(0, horizon))),
                     with: .linearGradient(Gradient(colors: [Color(red: 0.42, green: 0.62, blue: 0.9),
                                                             Color(red: 0.78, green: 0.88, blue: 0.97)]),
                                           startPoint: .zero, endPoint: CGPoint(x: 0, y: max(1, horizon))))
        context.fill(Path(CGRect(x: 0, y: horizon, width: size.width, height: size.height - horizon)),
                     with: .linearGradient(Gradient(colors: [Color(red: 0.55, green: 0.7, blue: 0.42),
                                                             Color(red: 0.33, green: 0.52, blue: 0.27)]),
                                           startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: 0, y: size.height)))
        // Mountains on the horizon, the same in both pictures (they are far away).
        var mountains = Path()
        mountains.move(to: CGPoint(x: 0, y: horizon))
        for step in 0...8 {
            let x = size.width * Double(step) / 8
            mountains.addLine(to: CGPoint(x: x, y: horizon - size.height * (step.isMultiple(of: 2) ? 0.04 : 0.11)))
        }
        mountains.addLine(to: CGPoint(x: size.width, y: horizon))
        mountains.closeSubpath()
        context.fill(mountains, with: .color(Color(red: 0.5, green: 0.58, blue: 0.7)))

        // Trees and the character, farthest first.
        enum Item { case tree(Tree), character }
        let items: [(Item, Double)] = trees.compactMap { tree in
            project(tree.x, 0, tree.z).map { (.tree(tree), $0.1) }
        } + [project(0, 0, 0).map { (.character, $0.1) }].compactMap { $0 }
        for (item, _) in items.sorted(by: { $0.1 > $1.1 }) {
            switch item {
            case .tree(let tree):
                guard let (base, _) = project(tree.x, 0, tree.z), let (top, _) = project(tree.x, tree.height, tree.z),
                      let (crownBottom, _) = project(tree.x, tree.height * 0.35, tree.z) else { continue }
                let crownWidth = (base.y - top.y) * 0.42
                var trunk = Path()
                trunk.addRect(CGRect(x: base.x - crownWidth * 0.08, y: crownBottom.y,
                                     width: crownWidth * 0.16, height: base.y - crownBottom.y))
                context.fill(trunk, with: .color(Color(red: 0.42, green: 0.3, blue: 0.2)))
                var crown = Path()
                crown.move(to: top)
                crown.addLine(to: CGPoint(x: base.x - crownWidth, y: crownBottom.y))
                crown.addLine(to: CGPoint(x: base.x + crownWidth, y: crownBottom.y))
                crown.closeSubpath()
                context.fill(crown, with: .color(Color(red: 0.16, green: 0.4, blue: 0.22)))
            case .character:
                guard let (feet, _) = project(0, 0, 0), let (head, _) = project(0, 1.7, 0) else { continue }
                let tall = feet.y - head.y, width = tall * 0.3
                context.fill(Path(ellipseIn: CGRect(x: feet.x - width * 0.9, y: feet.y - tall * 0.05,
                                                    width: width * 1.8, height: tall * 0.1)),
                             with: .color(.black.opacity(0.25)))
                context.fill(Path(roundedRect: CGRect(x: feet.x - width / 2, y: head.y + tall * 0.22,
                                                      width: width, height: tall * 0.78),
                                  cornerRadius: width * 0.35),
                             with: .color(Color(red: 0.85, green: 0.35, blue: 0.25)))
                context.fill(Path(ellipseIn: CGRect(x: feet.x - width * 0.38, y: head.y,
                                                    width: width * 0.76, height: width * 0.76)),
                             with: .color(Color(red: 0.98, green: 0.84, blue: 0.7)))
            }
        }
    }
}
#endif

#if os(macOS) && !targetEnvironment(macCatalyst)
/// The Camera reach page of a game's settings, reading and writing its settings file itself.
public struct GameCameraReachTab: View {
    let bundleIdentifier: String
    let saved: () -> Void
    @State private var warnings: [OnlineWarning.Feature] = []

    public init(bundleIdentifier: String, saved: @escaping () -> Void) {
        self.bundleIdentifier = bundleIdentifier
        self.saved = saved
    }

    public var body: some View {
        GameSettingsFile(bundleIdentifier: bundleIdentifier, saved: saved) { settings in
            Form {
                CameraReachSection(settings: settings.mulg.camera, bundleIdentifier: bundleIdentifier, warnings: $warnings)
            }
            .formStyle(.grouped)
            .onlineWarnings($warnings)
        }
    }
}
#endif
