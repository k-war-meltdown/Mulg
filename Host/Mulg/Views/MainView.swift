//
//  MainView.swift
//  Mulg
//

import MulgGUI
import SwiftUI

enum SidebarItem: Hashable {
    case home, library
}

struct MainView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.controlActiveState) var controlActiveState

    @EnvironmentObject var apps: AppsVM
    @EnvironmentObject var integrity: AppIntegrity

    @ObservedObject var mulgVaultObserved = MulgVaultObservable.shared

    @Binding public var isSigningSetupShown: Bool

    @AppStorage(GUIKey.onboardingDone) private var onboardingDone = false

    @State private var selection: SidebarItem? = .home
    /// A game Home asked to play; the App Library takes it, shows it and starts it.
    @State private var launchRequest: String?
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var navWidth: CGFloat = 0
    @State private var viewWidth: CGFloat = 0
    @State private var selectedBackgroundColor: Color = Color.accentColor
    @State private var selectedTextColor: Color = .primary


    private var collapsed: Bool { columns == .detailOnly }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
        } detail: {
            detail
        }
        .mulgWindowBackground()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewWidth = $0 }
        .onAppear { updateSelectionColors() }
        .onChange(of: colorScheme) { updateSelectionColors() }
        .onChange(of: controlActiveState) { updateSelectionColors() }
        .toastOverlay {
            HStack {
                // The sidebar floats in Liquid Glass, so the toast also clears its padding.
                let spacerWidth = navWidth + ToastView.toastGlassPadding
                if !collapsed {
                    Spacer()
                        .frame(width: spacerWidth)
                }
                ToastView()
                    .environmentObject(ToastVM.shared)
                    .environmentObject(InstallVM.shared)
                    .environmentObject(DownloadVM.shared)
                    // max keeps the width from going negative
                    .frame(width: max(0, collapsed || viewWidth < navWidth ? viewWidth : (viewWidth - spacerWidth)))
                    .animation(.spring(), value: collapsed)
            }
        }
        .alert("alert.moveAppToApplications.title",
               isPresented: $integrity.integrityOff) {
            Button("alert.moveAppToApplications.move", role: .cancel) {
                integrity.moveToApps()
            }
            .tint(.accentColor)
            .keyboardShortcut(.defaultAction)
        } message: {
            Text("alert.moveAppToApplications.subtitle")
        }
        .sheet(isPresented: $isSigningSetupShown) {
            SignSetupView(isSigningSetupShown: $isSigningSetupShown)
        }
        .sheet(isPresented: $mulgVaultObserved.isMulgVaultUnlockingPromptShown) {
            MulgVaultUnlockingPrompt()
        }
        .sheet(isPresented: Binding(get: { !onboardingDone }, set: { onboardingDone = !$0 })) {
            OnboardingView(onAddGame: {
                selection = .library
                AppLibraryView.addGame()
            })
        }
        .frame(minWidth: 760, minHeight: 460)
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Play") {
                Label { Text("Home") } icon: { MulgIcon("house.fill", tint: MulgIconTint.accent, size: 20) }
                    .tag(SidebarItem.home)
                Label { Text("sidebar.appLibrary") } icon: { MulgIcon("square.grid.2x2.fill", tint: MulgIconTint.indigo, size: 20) }
                    .badge(apps.apps.count)
                    .tag(SidebarItem.library)
            }
        }
        .navigationSplitViewColumnWidth(min: 214, ideal: 232, max: 300)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 10) {
                MulgLogo(size: 32)
                Text("Mulg").font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .safeAreaInset(edge: .bottom) {
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Mulg settings (⌘,)")
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { navWidth = $0 }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .home {
        case .home:
            HomeView(games: homeGames,
                     onPlay: play,
                     onAddGame: AppLibraryView.addGame,
                     onShowLibrary: { selection = .library })
        case .library:
            AppLibraryView(selectedBackgroundColor: $selectedBackgroundColor,
                           selectedTextColor: $selectedTextColor,
                           launchRequest: $launchRequest)
        }
    }

    private var homeGames: [HomeGame] {
        apps.apps.map { app in
            let info = app.info
            return HomeGame(
                id: info.bundleIdentifier,
                name: app.name,
                lastPlayed: UserDefaults.standard.object(forKey: GUIKey.lastPlayed(info.bundleIdentifier)) as? Date,
                loadIcon: {
                    let appURL = app.url
                    let bundleIdentifier = info.bundleIdentifier
                    let bundleVersion = info.bundleVersion
                    let primaryIconName = info.primaryIconName
                    let data = await Task.detached(priority: .utility) {
                        Cacher.shared.resolveLocalIconData(at: appURL, bundleIdentifier: bundleIdentifier,
                                                           bundleVersion: bundleVersion,
                                                           primaryIconName: primaryIconName)
                    }.value
                    return data.flatMap(NSImage.init(data:))
                })
        }
    }

    /// Home's Play opens the App Library on that game, which starts it there: its progress and
    /// running state show in the library, like a Play from the library itself.
    private func play(_ bundleIdentifier: String) async -> Bool {
        guard apps.apps.contains(where: { $0.info.bundleIdentifier == bundleIdentifier }) else { return false }
        launchRequest = bundleIdentifier
        selection = .library
        return true
    }

    /// Library tiles draw their own selection; they follow the window's key state like the sidebar.
    private func updateSelectionColors() {
        let active = controlActiveState != .inactive
        selectedTextColor = active ? .white : .primary
        selectedBackgroundColor = active ? MulgStyle.selection : .secondary.opacity(0.18)
    }
}

struct MainView_Previews: PreviewProvider {
    @State static var isSigningSetupShown = true

    static var previews: some View {
        MainView(isSigningSetupShown: $isSigningSetupShown)
            .environmentObject(InstallVM.shared)
            .environmentObject(AppsVM.shared)
            .environmentObject(StoreVM.shared)
            .environmentObject(AppIntegrity())
    }
}
