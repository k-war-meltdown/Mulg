//
//  AppLibraryView.swift
//  Mulg
//

import MulgGUI
import MulgLibrary
import SwiftUI

struct AppLibraryView: View {
    @EnvironmentObject var appsVM: AppsVM
    @EnvironmentObject var installVM: InstallVM
    @EnvironmentObject var downloadVM: DownloadVM

    @Binding var selectedBackgroundColor: Color
    @Binding var selectedTextColor: Color
    /// A game to show and start (Home's Play); taken and cleared here.
    @Binding var launchRequest: String?

    @State private var gridLayout = [GridItem(.adaptive(minimum: 148, maximum: 172), spacing: 16)]
    @State private var searchString = ""
    @State private var isList = UserDefaults.standard.bool(forKey: "AppLibraryView")
    @State private var selected: MulgGame?
    @State private var showSettings = false
    @State private var showLegacyConvertAlert = false
    @State private var showWrongfileTypeAlert = false
    @State var showKeymapSheet = false
    @State private var runStates: [String: GameWatcher.RunState] = [:]
    @State private var launching = false

    var body: some View {
        Group {
            if !appsVM.apps.isEmpty || appsVM.updatingApps {
                if !appsVM.updatingApps && appsVM.filteredApps.isEmpty {
                    ContentUnavailableView.search(text: searchString)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            AppDisplayView(apps: appsVM.filteredApps,
                                          selectedBackgroundColor: $selectedBackgroundColor,
                                          selectedTextColor: $selectedTextColor,
                                          selected: $selected,
                                          isList: $isList,
                                          gridLayout: gridLayout)
                        }
                        .background(Color.clear.contentShape(Rectangle()).onTapGesture { selected = nil })
                        .onExitCommand { selected = nil }
                        // A game chosen elsewhere (Home's Play) is brought into view.
                        .onChange(of: selected?.url) { _, url in
                            if let url { withAnimation { proxy.scrollTo(url, anchor: .center) } }
                        }
                    }
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
                        .padding(.bottom, 10)
                    Text("mulggame.noSources.title")
                        .font(.title)
                        .padding(.bottom, 2)
                    Text("mulggame.noSources.subtitle")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Button("mulggame.importIPA") {
                        AppLibraryView.addGame()
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("sidebar.appLibrary")
        .safeAreaInset(edge: .bottom) {
            if let selected {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selected.name).font(.headline).lineLimit(1)
                        let state = runStates[selected.info.bundleIdentifier]
                        HStack(spacing: 6) {
                            Circle()
                                .fill(state == .running ? Color.green : state == .closing ? Color.orange : Color.secondary.opacity(0.5))
                                .frame(width: 7, height: 7)
                            Text(state == .running ? "Running" : state == .closing ? "Closing…" : "Ready to play")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if launching { ProgressView().controlSize(.small) }
                    Button("Game details…", systemImage: "sidebar.right") { showSettings = true }
                    Button(runStates[selected.info.bundleIdentifier] == .running ? "Show game" : "Play", systemImage: "play.fill") {
                        launching = true
                        Task { _ = await selected.launch(); launching = false }
                    }.buttonStyle(.borderedProminent)
                        .disabled(launching || selected.isStarting || runStates[selected.info.bundleIdentifier] == .closing)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .mulgCard(radius: 16)
                .padding(.horizontal, 16).padding(.bottom, 14)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    AppLibraryView.addGame()
                } label: {
                    Image(systemName: "plus.circle")
                        .help("mulggame.add")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Spacer()
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .disabled(selected == nil)
                .help("Game details and settings")
            }
            ToolbarItem(placement: .primaryAction) {
                Picker("sidebar.layoutPicker", selection: $isList) {
                    Image(systemName: "square.grid.2x2")
                        .tag(false)
                    Image(systemName: "list.bullet")
                        .tag(true)
                }.pickerStyle(.segmented)
            }
        }
        .searchable(text: $searchString, placement: .toolbar)
        .onChange(of: searchString) { _, value in
            appsVM.searchText = value
            selected = nil
        }
        .onAppear {
            appsVM.searchText = searchString
            appsVM.fetchApps()
            startRequestedLaunch()
        }
        .onChange(of: launchRequest) { startRequestedLaunch() }
        .task {
            for await states in GameWatcher.runStateUpdates() { runStates = states }
        }
        .onChange(of: isList) { _, value in
            UserDefaults.standard.set(value, forKey: "AppLibraryView")
        }
        .sheet(isPresented: $showSettings) {
            if let selected = selected {
                AppSettingsView(viewModel: AppSettingsVM(app: selected), showKeymapSheet: $showKeymapSheet)
            }
        }
        .sheet(isPresented: $showKeymapSheet) {
            if let selected = selected {
                KeymapView(showKeymapSheet: $showKeymapSheet, viewModel: KeymapViewVM(app: selected))
            }
        }
        .onAppear {
            showLegacyConvertAlert = LegacySettings.doesMonolithExist
        }
        .onDrop(of: ["public.url", "public.file-url"], isTargeted: nil) { (items) -> Bool in
            if installVM.inProgress {
                Log.shared.error(MulgError.waitInstallation)
                return false
            } else if downloadVM.inProgress {
                Log.shared.error(MulgError.waitDownload)
                return false
            } else if let item = items.first {
                if let identifier = item.registeredTypeIdentifiers.first {
                    if identifier == "public.url" || identifier == "public.file-url" {
                        item.loadItem(forTypeIdentifier: identifier, options: nil) { (urlData, _) in
                            guard let urlData = urlData as? Data else { return }
                            Task { @MainActor in
                                let url = NSURL(absoluteURLWithDataRepresentation: urlData, relativeTo: nil) as URL
                                if url.pathExtension == "ipa" {
                                    AppLibraryView.installApp(url)
                                } else {
                                    showWrongfileTypeAlert = true
                                }
                            }
                        }
                    }
                }
                return true
            } else {
                return false
            }
        }
        .alert(isPresented: $showWrongfileTypeAlert) {
            Alert(title: Text("alert.wrongFileType.title"),
                  message: Text("alert.wrongFileType.subtitle"), dismissButton: .default(Text("button.OK")))
        }
        .alert("alert.legacyImport.title", isPresented: $showLegacyConvertAlert, actions: {
            Button("button.Convert", role: .destructive) {
                LegacySettings.convertLegacyMonolithPlist(LegacySettings.monolithURL)
                do {
                    try FileManager.default.removeItem(at: LegacySettings.monolithURL)
                } catch {
                    Log.shared.error(error)
                }
            }
            .keyboardShortcut(.defaultAction)
            Button("button.Cancel", role: .cancel) {
                showLegacyConvertAlert.toggle()
            }
        }, message: {
            Text("alert.legacyImport.subtitle")
        })
    }

    /// Home's Play: select the game here, in view, and start it exactly like the Play button
    /// below, so its progress and running state show in the library. The launch runs in its own
    /// task, so leaving the view does not cancel it.
    private func startRequestedLaunch() {
        guard let identifier = launchRequest else { return }
        launchRequest = nil
        if !searchString.isEmpty { searchString = "" }  // a search must not hide the game
        Task { @MainActor in
            // The library may still be refreshing; it reuses unchanged game objects.
            var game = appsVM.apps.first { $0.info.bundleIdentifier == identifier }
            for _ in 0..<20 where game == nil {
                try? await Task.sleep(for: .milliseconds(100))
                game = appsVM.apps.first { $0.info.bundleIdentifier == identifier }
            }
            guard let game else { return }
            await Task.yield()  // after the search reset, which clears the selection
            selected = game
            guard !launching, !game.isStarting else { return }
            launching = true
            _ = await game.launch()
            launching = false
        }
    }

    /// Installs an .ipa and refreshes the library. Also used by the Home page. Asks for the install
    /// folder first when Settings > Install says so; cancelling there cancels the install.
    static func installApp(_ url: URL) {
        guard let folder = InstallPreferences.shared.destinationForInstall() else { return }
        Installer.install(ipaUrl: url, export: false, into: folder, returnCompletion: { installed in
            Task { @MainActor in
                AppsVM.shared.fetchApps()
                guard installed != nil else { return }
                NotifyService.shared.notify(
                    NSLocalizedString("notification.appInstalled", comment: ""),
                    NSLocalizedString("notification.appInstalled.message", comment: ""))
            }
        })
    }

    /// Asks for an .ipa and installs it, unless an install or download is running.
    static func addGame() {
        if InstallVM.shared.inProgress {
            Log.shared.error(MulgError.waitInstallation)
        } else if DownloadVM.shared.inProgress {
            Log.shared.error(MulgError.waitDownload)
        } else {
            NSOpenPanel.selectIPA { result in
                if case .success(let url) = result {
                    installApp(url)
                }
            }
        }
    }
}

struct AppDisplayView: View {
    var apps: [MulgGame]
    @Binding var selectedBackgroundColor: Color
    @Binding var selectedTextColor: Color
    @Binding var selected: MulgGame?
    @Binding var isList: Bool

    // Implementation of ViewModels to preserve
    // UI states between list & grid view.
    @State private var viewModels: [String: MulgGameVM] = [:]

    var gridLayout: [GridItem]
    var mulgGameViews: some View {
        ForEach(apps, id: \.url) { app in
            let viewModel = viewModels[app.url.absoluteString, default: MulgGameVM(app: app)]
            MulgGameView(selectedBackgroundColor: $selectedBackgroundColor,
                        selectedTextColor: $selectedTextColor,
                        selected: $selected,
                        isList: $isList,
                        viewModel: viewModel)
                .onAppear {
                    viewModels[app.url.absoluteString] = viewModel
                }
        }
    }

    var body: some View {
        if isList {
            VStack {
                mulgGameViews
                Spacer()
            }
            .padding()
        } else {
            LazyVGrid(columns: gridLayout, alignment: .leading, spacing: 18) {
                mulgGameViews
            }
            .padding()
        }
    }
}
