// Host-side module: the Mulg app is a native macOS app, never Mac Catalyst.
#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import MulgContracts
import MulgLibrary
import MulgStore
import SwiftUI

/// Save backup, diagnostics export and result sharing on a game's settings page
/// (PLAN.md §8.2, §8.3, §13.3). Nothing leaves the Mac unless the user sends it.
public struct GameServicesSection: View {
    let settings: GameSettings
    /// Runs after a restore replaced the settings file, so screens holding a copy read it again.
    let restored: () -> Void
    @State private var operation: ServiceOperation?
    /// A backup picked to restore, shown for the user to confirm before it replaces anything.
    @State private var pendingRestore: PendingRestore?
    /// Why an operation could not start (game running, wrong folder).
    @State private var refusal: String?

    public init(settings: GameSettings, restored: @escaping () -> Void = {}) {
        self.settings = settings
        self.restored = restored
    }

    private var isWorking: Bool { operation?.isRunning ?? false }

    public var body: some View {
        Section(String(localized: "Saves and reports", bundle: .module)) {
            Group {
                Button(String(localized: "Back up saves…", bundle: .module)) { backUp() }
                Button(String(localized: "Restore saves…", bundle: .module)) { restore() }
                Button(String(localized: "Export diagnostics…", bundle: .module)) { export() }
            }
            .disabled(isWorking)
            Text("Quit the game before backing up or restoring saves.", bundle: .module)
                .font(.caption).foregroundStyle(.secondary)
            if let repository = MulgRepository.current(),
               let url = ShareResult.issueURL(repository: repository, settings: settings, works: true, mac: .current()) {
                // Opens a pre-filled issue in the browser; the user reviews and submits it.
                Link(String(localized: "Share this game's result", bundle: .module), destination: url)
            }
            if let refusal {
                Text(refusal).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let operation {
                ServiceOperationView(operation: operation)
            }
        }
        .interactiveDismissDisabled(isWorking)
        .confirmationDialog(String(localized: "Restore saves?", bundle: .module),
                            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
                            titleVisibility: .visible, presenting: pendingRestore) { pending in
            Button(String(localized: "Restore", bundle: .module), role: .destructive) { startRestore(pending.version) }
            Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
        } message: { pending in
            Text(pending.message(game: settings.bundleIdentifier))
        }
    }

    private func backUp() {
        guard let folder = choose(String(localized: "Choose a backup folder", bundle: .module), start: nil) else { return }
        let game = settings.bundleIdentifier
        start(.backup, destination: folder.appendingPathComponent(game, isDirectory: true), changeLocation: backUp) { report in
            try SaveBackup(folder: folder).backUp(game, progress: report)
        }
    }

    private func restore() {
        guard let version = choose(String(localized: "Choose a dated backup", bundle: .module), start: nil) else { return }
        // The game may have been started while the folder picker was open.
        guard !GameWatcher.isRunning(settings.bundleIdentifier) else {
            refusal = String(localized: "Quit the game before restoring.", bundle: .module)
            return
        }
        // Versions live in `<folder>/<bundle ID>/`: another game's saves would replace this one's.
        guard version.deletingLastPathComponent().lastPathComponent == settings.bundleIdentifier else {
            refusal = String(localized: "That backup belongs to another game. Pick a dated folder inside this game's backup folder.", bundle: .module)
            return
        }
        guard let preview = SaveBackup.preview(of: version) else {
            refusal = SaveBackup.Failure.notAVersion(version.path).description
            return
        }
        refusal = nil
        pendingRestore = PendingRestore(version: version, preview: preview)
    }

    /// After the user confirmed the preview. The current saves are backed up first, next to the
    /// backup being restored, so a wrong pick can be undone.
    private func startRestore(_ version: URL) {
        let backup = SaveBackup(folder: version.deletingLastPathComponent().deletingLastPathComponent())
        let game = settings.bundleIdentifier
        start(.restore, destination: version, then: restored) { report in
            try backup.restore(version, bundleIdentifier: game, progress: report)
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(settings.bundleIdentifier) diagnostics.zip"
        guard panel.runModal() == .OK, let archive = panel.url else { return }
        let settings = settings
        start(.export, destination: archive, changeLocation: export) { report in
            try DiagnosticsExport.export(settings, to: archive, progress: report)
            return archive
        }
    }

    private func choose(_ title: String, start: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.message = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = start
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Runs a backup, restore or export off the main thread (large saves take a while), showing its
    /// stage and where it writes. `then` runs after a success; `changeLocation` picks another place.
    private func start(_ kind: ServiceOperation.Kind, destination: URL, changeLocation: (() -> Void)? = nil,
                       then done: @escaping () -> Void = {},
                       work: @escaping @Sendable (@escaping @Sendable (OperationProgress) -> Void) throws -> URL) {
        guard !isWorking else { return }
        refusal = nil
        let operation = ServiceOperation(kind: kind, destination: destination, changeLocation: changeLocation, retry: {
            start(kind, destination: destination, changeLocation: changeLocation, then: done, work: work)
        })
        self.operation = operation
        operation.run(work, then: done)
    }
}

/// A restore the user still has to confirm.
private struct PendingRestore {
    let version: URL
    let preview: SaveBackup.Preview

    func message(game: String) -> String {
        let when = preview.date?.formatted(date: .abbreviated, time: .shortened) ?? version.lastPathComponent
        let items = preview.items.map { item in
            let size = ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
            switch item.part {
            case .gameData: return String(localized: "• Saved game data (\(size))", bundle: .module)
            case .settings: return String(localized: "• This game's settings", bundle: .module)
            case .keymaps: return String(localized: "• Keymaps (\(size))", bundle: .module)
            }
        }
        return String(localized: "The backup of \(game) from \(when) will replace:", bundle: .module)
            + "\n" + items.joined(separator: "\n") + "\n"
            + String(localized: "Your current saves are backed up first, so this can be undone.", bundle: .module)
    }
}

/// One backup, restore or export: where it is, and how it ended. Cancelling is offered only while
/// nothing has been replaced yet.
@MainActor @Observable
final class ServiceOperation {
    enum Kind { case backup, restore, export }
    enum Outcome { case done(URL), failed(String), cancelled }

    let kind: Kind
    let destination: URL
    let changeLocation: (() -> Void)?
    let retry: () -> Void
    private(set) var progress: OperationProgress?
    private(set) var outcome: Outcome?
    private(set) var isCancelling = false
    private var worker: Task<Result<URL, any Error>, Never>?

    var isRunning: Bool { outcome == nil }

    init(kind: Kind, destination: URL, changeLocation: (() -> Void)?, retry: @escaping () -> Void) {
        self.kind = kind
        self.destination = destination
        self.changeLocation = changeLocation
        self.retry = retry
    }

    func run(_ work: @escaping @Sendable (@escaping @Sendable (OperationProgress) -> Void) throws -> URL,
             then done: @escaping () -> Void) {
        // Reports can arrive out of order; the bar never goes back.
        let report: @Sendable (OperationProgress) -> Void = { [weak self] update in
            Task { @MainActor in
                guard let self, update.completed >= (self.progress?.completed ?? 0) else { return }
                self.progress = update
            }
        }
        let worker = Task.detached(priority: .userInitiated) { Result { try work(report) } }
        self.worker = worker
        Task {
            switch await worker.value {
            case let .success(url):
                outcome = .done(url)
                done()
            case .failure(is CancellationError):
                outcome = .cancelled
            case let .failure(error):
                outcome = .failed(String(describing: error))
            }
        }
    }

    func cancel() {
        isCancelling = true
        worker?.cancel()
    }
}

private struct ServiceOperationView: View {
    let operation: ServiceOperation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch operation.outcome {
            case nil: running
            case let .done(url): done(url)
            case .cancelled:
                Text("Cancelled. Nothing was changed.", bundle: .module).foregroundStyle(.secondary)
            case let .failed(message):
                Text(message).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                recovery
            }
        }
    }

    private var title: String {
        switch operation.kind {
        case .backup: String(localized: "Backing up saves", bundle: .module)
        case .restore: String(localized: "Restoring saves", bundle: .module)
        case .export: String(localized: "Exporting diagnostics", bundle: .module)
        }
    }

    private func stageText(_ stage: OperationProgress.Stage) -> String {
        let restoring = operation.kind == .restore
        return switch stage {
        case .gameData: restoring ? String(localized: "Putting back saved data", bundle: .module)
            : String(localized: "Zipping saved data", bundle: .module)
        case .settings: restoring ? String(localized: "Putting back settings", bundle: .module)
            : String(localized: "Copying settings", bundle: .module)
        case .keymaps: restoring ? String(localized: "Putting back keymaps", bundle: .module)
            : String(localized: "Zipping keymaps", bundle: .module)
        case .safetyCopy: String(localized: "Backing up the current saves first", bundle: .module)
        case .logs: String(localized: "Collecting recent logs (a few seconds)", bundle: .module)
        case .measurements: String(localized: "Adding measurements", bundle: .module)
        case .archive: String(localized: "Writing the zip", bundle: .module)
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if let progress = operation.progress {
                ProgressView(value: Double(progress.completed), total: Double(progress.total))
                Text(stageText(progress.stage)).font(.callout)
            } else {
                ProgressView().controlSize(.small)
            }
            LabeledContent(operation.kind == .restore ? String(localized: "From", bundle: .module)
                           : String(localized: "To", bundle: .module), value: operation.destination.path)
                .font(.caption)
                .textSelection(.enabled)
            if operation.progress?.canCancel ?? true {
                Button(operation.isCancelling ? String(localized: "Cancelling…", bundle: .module)
                       : String(localized: "Cancel", bundle: .module), role: .cancel) { operation.cancel() }
                    .disabled(operation.isCancelling)
            } else {
                Text("Replacing your saves: this can't be cancelled now.", bundle: .module)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func done(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                switch operation.kind {
                case .backup: Text("Backed up to \(url.path)", bundle: .module)
                case .restore: Text("Saves restored. Your previous saves are in \(url.path)", bundle: .module)
                case .export: Text("Saved to \(url.path)", bundle: .module)
                }
            }
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            Button(String(localized: "Show in Finder", bundle: .module)) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    /// What can be done after a failure: again, somewhere else, or look at what is on disk.
    private var recovery: some View {
        HStack {
            Button(String(localized: "Try Again", bundle: .module), action: operation.retry)
            if let changeLocation = operation.changeLocation {
                Button(String(localized: "Choose Another Location…", bundle: .module), action: changeLocation)
            }
            if operation.kind == .restore {
                // The safety copies and every other version sit next to the backup that was picked.
                Button(String(localized: "Show Backups in Finder", bundle: .module)) {
                    NSWorkspace.shared.open(operation.destination.deletingLastPathComponent())
                }
            }
        }
    }
}

/// The library's compatibility badges (§13.3).
public struct CompatibilityBadges: View {
    let profile: GameProfile?

    public init(profile: GameProfile?) {
        self.profile = profile
    }

    public var body: some View {
        HStack {
            ForEach(Array(GameProfile.badges(for: profile).enumerated()), id: \.offset) { _, badge in
                Text(badge.title)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .background(.quaternary, in: Capsule())
            }
        }
    }
}

extension GameProfile.Badge {
    var title: String {
        switch self {
        case .works: String(localized: "Works", bundle: .module)
        case .fps120: String(localized: "120 FPS confirmed", bundle: .module)
        case .metalFXTested: String(localized: "MetalFX tested", bundle: .module)
        case let .bestIdentifier(model): model
        case .notTested: String(localized: "Not tested yet", bundle: .module)
        }
    }
}

/// MulgSign without the password (PLAN.md §12.1 #6): the command to paste into Terminal,
/// and the one that undoes it.
public struct MulgSignView: View {
    @State private var status = MulgSign.status()

    public init() {}

    public var body: some View {
        Form {
            Text(String(localized: "MulgSign turns off a macOS security check (Apple Mobile File Integrity) for every app on this Mac, not just games. Only use it if a game needs it, and undo it when you are done.", bundle: .module))
                .foregroundStyle(.red)
            LabeledContent(String(localized: "System Integrity Protection off", bundle: .module),
                           value: status.sipDisabled ? "✓" : "✗")
            LabeledContent(String(localized: "MulgSign active", bundle: .module), value: status.active ? "✓" : "✗")
            command(String(localized: "Turn on (run in Terminal, then restart)", bundle: .module),
                    MulgSign.enableCommand(currentBootArguments: status.bootArguments))
            command(String(localized: "Turn off (run in Terminal, then restart)", bundle: .module),
                    MulgSign.disableCommand(currentBootArguments: status.bootArguments))
            Button(String(localized: "Check again", bundle: .module)) { status = MulgSign.status() }
        }
    }

    private func command(_ title: String, _ text: String) -> some View {
        Section(title) {
            Text(text).font(.body.monospaced()).textSelection(.enabled)
            Button(String(localized: "Copy", bundle: .module)) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }
}
#endif
