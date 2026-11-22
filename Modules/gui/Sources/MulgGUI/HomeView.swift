// Host-side module: the Mulg app is a native macOS app, never Mac Catalyst.
#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import MulgContracts
import MulgLibrary
import SwiftUI

/// One installed game as the Home page shows it. The app fills these in from its library.
public struct HomeGame: Identifiable {
    /// The bundle ID.
    public let id: String
    public let name: String
    public let lastPlayed: Date?
    public let loadIcon: @MainActor () async -> NSImage?

    public init(id: String, name: String, lastPlayed: Date?, loadIcon: @escaping @MainActor () async -> NSImage?) {
        self.id = id
        self.name = name
        self.lastPlayed = lastPlayed
        self.loadIcon = loadIcon
    }
}

/// The Home page, the first thing in the sidebar: a welcome banner, what this Mac can do, and
/// the games played most recently.
public struct HomeView: View {
    let games: [HomeGame]
    /// Starts a game; false when it could not be opened.
    let onPlay: (String) async -> Bool
    let onAddGame: () -> Void
    let onShowLibrary: () -> Void

    @State private var checks: [MacCheck] = []
    @State private var runStates: [String: GameWatcher.RunState] = [:]

    public init(games: [HomeGame], onPlay: @escaping (String) async -> Bool, onAddGame: @escaping () -> Void,
                onShowLibrary: @escaping () -> Void) {
        self.games = games
        self.onPlay = onPlay
        self.onAddGame = onAddGame
        self.onShowLibrary = onShowLibrary
    }

    /// Played games first, most recent first; then the rest by name.
    static func recent(_ games: [HomeGame], limit: Int = 12) -> [HomeGame] {
        Array(games.sorted { lhs, rhs in
            switch (lhs.lastPlayed, rhs.lastPlayed) {
            case let (left?, right?): left > right
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }.prefix(limit))
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                statusStrip
                if games.isEmpty {
                    firstGame
                } else {
                    recentGames
                }
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .background(EmberGlow())
        .navigationTitle(String(localized: "Home", bundle: .module))
        .onAppear { checks = MacCheck.run(.current()) }
        // Low Power Mode and the main display can change while Home is open.
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification))
            .receive(on: DispatchQueue.main)) { _ in
            checks = MacCheck.run(.current())
        }
        // Cards show Running (or Closing) while a game is open, whoever opened it.
        .task {
            for await states in GameWatcher.runStateUpdates() { runStates = states }
        }
    }

    /// The last game played, ready to continue; the welcome banner until a game has been played.
    @ViewBuilder private var hero: some View {
        if let last = Self.recent(games).first, last.lastPlayed != nil {
            ContinueCard(game: last, runState: runStates[last.id], play: { await onPlay(last.id) },
                         onAddGame: onAddGame, onShowLibrary: onShowLibrary)
        } else {
            welcomeHero
        }
    }

    /// The wide banner has the logo beside the text; a narrow window gets the logo small on top of it.
    private var welcomeHero: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) {
                heroText(size: 29)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 12) {
                heroText(size: 24)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .mulgCard(radius: 18)
    }

    private func heroText(size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.greeting()).font(.system(size: size, weight: .semibold))
            Text(String(localized: "Your iPad games, tuned for this Mac.", bundle: .module))
                .font(.title3)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button(action: onAddGame) {
                    Label(String(localized: "Add Game", bundle: .module), systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
                Button(action: onShowLibrary) {
                    Label(String(localized: "Open Library", bundle: .module), systemImage: "square.grid.2x2")
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
            .padding(.top, 8)
        }
    }

    private var statusStrip: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            stat("square.grid.2x2.fill", "\(games.count)", String(localized: "Games", bundle: .module), .ok)
            ForEach(checks.filter { ["chip", "display", "power"].contains($0.id) }) { check in
                stat(Self.symbol(for: check.id), check.title, check.detail, check.state)
            }
        }
    }

    private var recentGames: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "Jump Back In", bundle: .module)).font(.title2.bold())
                Spacer()
                Button(String(localized: "See All", bundle: .module), action: onShowLibrary)
                    .buttonStyle(.link)
            }
            ScrollView(.horizontal) {
                LazyHStack(spacing: 16) {
                    ForEach(Self.recent(games)) { game in
                        GameCard(game: game, runState: runStates[game.id]) { await onPlay(game.id) }
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.never)
        }
    }

    private var firstGame: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Add your first game", bundle: .module)).font(.title2.bold())
            // Three side by side when they fit, one under another in a narrow window.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { steps }
                VStack(spacing: 12) { steps }
            }
        }
    }

    @ViewBuilder private var steps: some View {
        step(1, "doc.badge.arrow.up", String(localized: "Get a decrypted .ipa of a game you own.", bundle: .module))
        step(2, "arrow.down.to.line", String(localized: "Drop it on the Library, or click Add Game.", bundle: .module))
        step(3, "play.fill", String(localized: "Pick a profile and play.", bundle: .module))
    }

    private func stat(_ symbol: String, _ value: String, _ label: String, _ state: ReadinessCheck.State) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(state == .ok ? AnyShapeStyle(MulgStyle.accent) : AnyShapeStyle(state.color))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.headline).lineLimit(1)
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .mulgCard(radius: 16)
    }

    private func step(_ number: Int, _ symbol: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(verbatim: "\(number)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(MulgStyle.ember, in: Circle())
                Spacer()
                Image(systemName: symbol).foregroundStyle(.secondary)
            }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .mulgCard(radius: 16)
    }

    static func symbol(for check: String) -> String {
        switch check {
        case "chip": "cpu"
        case "display": "display"
        case "power": "bolt.batteryblock.fill"
        default: "checkmark.circle"
        }
    }

    static func greeting(at date: Date = .now) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: String(localized: "Good morning", bundle: .module)
        case 12..<18: String(localized: "Good afternoon", bundle: .module)
        default: String(localized: "Good evening", bundle: .module)
        }
    }
}

/// The Home banner once a game has been played: the last one, its icon glowing softly behind it, and one
/// button to continue (2026-10-10 polish).
struct ContinueCard: View {
    let game: HomeGame
    let runState: GameWatcher.RunState?
    let play: () async -> Bool
    let onAddGame: () -> Void
    let onShowLibrary: () -> Void

    @State private var icon: NSImage?
    @State private var starting = false
    @State private var failed = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var isRunning: Bool { runState == .running }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 22) { artwork(size: 96); details; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 14) { artwork(size: 64); details }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(22)
        .background { glow }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .mulgCard(radius: 22)
        .task(id: game.id) { icon = await game.loadIcon() }
    }

    private func artwork(size: CGFloat) -> some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(.quaternary)
                    .overlay(Image(systemName: "gamecontroller").font(.title).foregroundStyle(.tertiary))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
        .overlay(alignment: .topTrailing) {
            if isRunning { MulgLiveDot().padding(5).background(.regularMaterial, in: Circle()).offset(x: 5, y: -5) }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(isRunning ? String(localized: "Playing now", bundle: .module) : HomeView.greeting())
                .font(.callout.weight(.medium)).foregroundStyle(.secondary)
            Text(game.name).font(.system(size: 28, weight: .bold)).lineLimit(1).truncationMode(.tail)
            if let lastPlayed = game.lastPlayed, !isRunning {
                Text(String(localized: "Last played \(lastPlayed.formatted(.relative(presentation: .named)))", bundle: .module))
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button(action: resume) {
                    Label(resumeTitle, systemImage: isRunning ? "macwindow" : failed ? "exclamationmark.triangle.fill" : "play.fill")
                }
                .buttonStyle(.glassProminent)
                .disabled(starting && !isRunning)
                Button(action: onAddGame) { Label(String(localized: "Add Game", bundle: .module), systemImage: "plus") }
                    .buttonStyle(.glass)
                Button(action: onShowLibrary) {
                    Label(String(localized: "Library", bundle: .module), systemImage: "square.grid.2x2")
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
            .padding(.top, 8)
        }
    }

    private var resumeTitle: String {
        if isRunning { String(localized: "Bring Forward", bundle: .module) }
        else if starting { String(localized: "Starting…", bundle: .module) }
        else if failed { String(localized: "Launch Failed – Retry", bundle: .module) }
        else { String(localized: "Continue", bundle: .module) }
    }

    /// The game's own colours, blurred far beyond recognition: the banner takes on the game's mood.
    @ViewBuilder private var glow: some View {
        if let icon, !reduceTransparency {
            Image(nsImage: icon).resizable().scaledToFill()
                .blur(radius: 60).saturation(1.3).opacity(0.32)
                .accessibilityHidden(true)
        }
    }

    private func resume() {
        if isRunning {
            GameWatcher.process(game.id)?.activate()
            return
        }
        guard !starting else { return }
        starting = true
        failed = false
        Task {
            failed = !(await play())
            starting = false
        }
    }
}

/// A game tile is a real button, reachable by keyboard with a visible Play affordance.
struct GameCard: View {
    let game: HomeGame
    let runState: GameWatcher.RunState?
    private var isRunning: Bool { runState == .running }
    private var closing: Bool { runState == .closing }
    let play: () async -> Bool

    @State private var icon: NSImage?
    @State private var starting = false
    @State private var failed = false
    @State private var hovering = false
    @State private var resolution = ResolutionMode.auto
    @State private var settingsProblem: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: primary) {
            VStack(spacing: 10) {
                ZStack {
                    if let icon {
                        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.quaternary)
                            .overlay(Image(systemName: "gamecontroller").font(.title).foregroundStyle(.tertiary))
                    }
                }
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(hovering ? 0.3 : 0.15), radius: hovering ? 14 : 6, y: hovering ? 8 : 3)
                .overlay(alignment: .topTrailing) {
                    if isRunning {
                        MulgLiveDot().padding(5).background(.regularMaterial, in: Circle()).offset(x: 5, y: -5)
                    }
                }
                Text(game.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 132, height: 36, alignment: .top)
                status
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(failed && !isRunning ? AnyShapeStyle(.orange) : AnyShapeStyle(MulgStyle.accent))
            }
            .padding(14)
            .mulgCard(radius: 16)
        }
        .buttonStyle(MulgPressStyle())
        .disabled((starting && !isRunning) || closing)
        .scaleEffect(hovering && !reduceMotion ? 1.025 : 1)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(action: primary) { status }
            Picker(selection: Binding(get: { resolution }, set: setResolution)) {
                ForEach(GameActions.resolutionOptions(current: resolution), id: \.self) { Text(Self.title($0)).tag($0) }
            } label: {
                Label(String(localized: "Resolution", bundle: .module), systemImage: "display")
            }
            .onAppear { resolution = GameActions().resolution(game.id) }
            Toggle(isOn: Binding(get: { GameActions().forcesRenderResolution(game.id) },
                                 set: { try? GameActions().setForcesRenderResolution($0, for: game.id) })) {
                Label(String(localized: "Force selected resolution", bundle: .module), systemImage: "arrow.up.left.and.arrow.down.right")
            }
        }
        .help(game.name)
        .accessibilityLabel(Text(game.name))
        .accessibilityHint(statusTitle)
        .alert(String(localized: "Settings couldn't be saved", bundle: .module),
               isPresented: Binding(get: { settingsProblem != nil }, set: { if !$0 { settingsProblem = nil } })) {
            Button(String(localized: "OK", bundle: .module), role: .cancel) {}
        } message: {
            Text(settingsProblem ?? "")
        }
        .task(id: game.id) {
            resolution = GameActions().resolution(game.id)
            icon = await game.loadIcon()
        }
    }

    /// Running, starting, failed or ready, in that order: a game that opened after all is running.
    private var status: some View {
        Label(statusTitle, systemImage: isRunning ? "macwindow" : starting || closing ? "hourglass"
              : failed ? "exclamationmark.triangle.fill" : "play.fill")
    }

    private var statusTitle: String {
        if isRunning { String(localized: "Bring Forward", bundle: .module) }
        else if closing { String(localized: "Closing…", bundle: .module) }
        else if starting { String(localized: "Starting…", bundle: .module) }
        else if failed { String(localized: "Launch Failed – Retry", bundle: .module) }
        else { String(localized: "Play", bundle: .module) }
    }

    /// One launch at a time; a running game is brought to the front instead.
    private func primary() {
        if isRunning {
            GameWatcher.process(game.id)?.activate()
            return
        }
        guard !starting else { return }
        starting = true
        failed = false
        Task {
            failed = !(await play())
            starting = false
        }
    }

    private func setResolution(_ mode: ResolutionMode) {
        do {
            try GameActions().setResolution(mode, for: game.id)
            resolution = GameActions().resolution(game.id)
        } catch {
            settingsProblem = String(describing: error)
        }
    }

    static func title(_ mode: ResolutionMode) -> String {
        switch mode {
        case .native4K: String(localized: "4K native (3840 × 2160)", bundle: .module)
        case .native5K: String(localized: "5K native (5120 × 2880)", bundle: .module)
        case .matchDevice: String(localized: "iPad screen (selected device)", bundle: .module)
        case .off: String(localized: "Adaptive display off", bundle: .module)
        case .auto: String(localized: "Match Mac display", bundle: .module)
        case .p1080: "1080p"
        case .p1440: "1440p"
        case .p2160: "2160p"
        case .custom: String(localized: "Custom resolution", bundle: .module)
        case .resizable: String(localized: "Resizable window", bundle: .module)
        case .display: String(localized: "This display (native pixels and Hz)", bundle: .module)
        }
    }
}
#endif
