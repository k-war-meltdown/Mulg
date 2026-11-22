//
//  MulgGameView.swift
//  Mulg
//

import MulgContracts
import MulgGUI
import MulgLibrary
import SwiftUI

struct MulgGameView: View {

    @Binding var selectedBackgroundColor: Color
    @Binding var selectedTextColor: Color
    @Binding var selected: MulgGame?
    @Binding var isList: Bool

    @StateObject var viewModel: MulgGameVM

    var body: some View {
        MulgGameConditionalView(selectedBackgroundColor: $selectedBackgroundColor,
                               selectedTextColor: $selectedTextColor,
                               selected: $selected,
                               showStartingProgress: $viewModel.showStartingProgress,
                               app: viewModel.app,
                               isList: isList)
            .gesture(TapGesture(count: 2).onEnded {
                // Launch the app from a separate thread (allow us to Sayori it if needed)
                Task(priority: .userInitiated) {
                    if !viewModel.app.isStarting {
                        viewModel.showStartingProgress = true
                        await viewModel.app.launch()
                        viewModel.showStartingProgress = false
                    }
                }
            })
            .simultaneousGesture(TapGesture().onEnded {
                selected = viewModel.app
            })
            .contextMenu {
                Button("Game details…", systemImage: "sidebar.right", action: {
                    viewModel.showSettings.toggle()
                })
                Button("Play / Show game", systemImage: "play.fill") {
                    Task { _ = await viewModel.app.launch() }
                }
                Button("mulggame.openCache", systemImage: "folder", action: {
                    viewModel.app.openAppCache()
                })
                Button("mulggame.showInFinder", systemImage: "finder", action: {
                    viewModel.app.showInFinder()
                })
                Picker(selection: Binding(get: { viewModel.app.settings.settings.resolution },
                                          set: { setResolution($0) })) {
                    Text("iPad Pro (M5) screen").tag(7)
                    Text("4K native (3840 × 2160)").tag(8)
                    Text("5K native (5120 × 2880)").tag(9)
                    Text("This display (\(Self.displayPixels))").tag(10)
                } label: {
                    Label("Resolution", systemImage: "display")
                }
                Toggle(isOn: Binding(get: { GameActions().forcesRenderResolution(bundleIdentifier) },
                                     set: { try? GameActions().setForcesRenderResolution($0, for: bundleIdentifier) })) {
                    Label("Force selected resolution", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                // The game either sees the iPad Pro (M5) CPU, or the Mac's cores and sizes its threads for all of them.
                Picker(selection: Binding(get: { GameActions().usesEveryMacCore(bundleIdentifier) },
                                          set: { try? GameActions().setUsesEveryMacCore($0, for: bundleIdentifier) })) {
                    Text("iPad Pro (M5): 9 cores").tag(false)
                    Text("Every Mac core (\(ProcessInfo.processInfo.activeProcessorCount))").tag(true)
                } label: {
                    Label("CPU cores", systemImage: "cpu")
                }
                Divider()
                Group {
                    Button("mulggame.keymap", systemImage: "keyboard", action: {
                        viewModel.showKeymapSheet.toggle()
                    })
                }
                Divider()
                Group {
                    Button("mulggame.clearCache", systemImage: "clear", action: {
                        selected = nil
                        Task { await Uninstaller.clearCachePopup(viewModel.app) }
                    })
                    Button("mulggame.clearPreferences", systemImage: "clear", action: {
                        viewModel.showClearPreferencesAlert.toggle()
                    })
                    Button("mulggame.clearMulgChain", systemImage: "clear", action: {
                        viewModel.showClearMulgChainAlert.toggle()
                    })
                }
                Divider()
                Button("mulggame.delete", systemImage: "trash", action: {
                    selected = nil
                    Task { await Uninstaller.uninstallPopup(viewModel.app) }
                })
                Button("Remove game and all data…", systemImage: "trash.slash", action: {
                    selected = nil
                    Task { await Uninstaller.removeCompletelyPopup(viewModel.app) }
                })
            }
            .alert("alert.app.preferences", isPresented: $viewModel.showClearPreferencesAlert) {
                Button("button.Proceed", role: .destructive) {
                    deletePreferences(app: viewModel.app.info.bundleIdentifier)
                    viewModel.showClearPreferencesAlert.toggle()
                }
                Button("button.Cancel", role: .cancel) { }
            }
            .alert("alert.app.clearMulgChain", isPresented: $viewModel.showClearMulgChainAlert) {
                Button("button.Proceed", role: .destructive) {
                    viewModel.showClearMulgChainAlert.toggle()
                    do { try viewModel.app.clearMulgChain() }
                    catch { Task { await Uninstaller.showCleanupFailure(error) } }
                }
                Button("button.Cancel", role: .cancel) { }
            }
            .sheet(isPresented: $viewModel.showSettings) {
                AppSettingsView(viewModel: AppSettingsVM(app: viewModel.app),
                                showKeymapSheet: $viewModel.showKeymapSheet)
            }
            .sheet(isPresented: $viewModel.showKeymapSheet) {
                KeymapView(showKeymapSheet: $viewModel.showKeymapSheet, viewModel: KeymapViewVM(app: viewModel.app))
            }
    }

    var bundleIdentifier: String { viewModel.app.info.bundleIdentifier }

    /// The Home cards' rule (GameActions), so the iPad screen follows the selected device.
    /// The main display's pixels, as "This display" captures them.
    static var displayPixels: String {
        guard let screen = NSScreen.main else { return "native pixels and Hz" }
        let scale = screen.backingScaleFactor
        return "\(Int(screen.frame.width * scale)) × \(Int(screen.frame.height * scale))"
    }

    func setResolution(_ mode: Int) {
        do {
            try GameActions().setResolution(ResolutionMode(setting: mode), for: bundleIdentifier)
        } catch {
            Log.shared.error(error)
        }
        viewModel.app.settings.decode()
        viewModel.objectWillChange.send()
    }

    func deletePreferences(app: String) {
        do {
            let lease = try GameCleanup.acquireLease(app)
            defer { withExtendedLifetime(lease) {} }
            let plistURL = ContainerPaths.current().gameContainer(for: app)
                .appendingPathComponent("Data/Library/Preferences")
                .appendingPathComponent(app).appendingPathExtension("plist")

            guard FileManager.default.fileExists(atPath: plistURL.path) else { return }

            try FileManager.default.removeItem(atPath: plistURL.path)
        } catch {
            Task { await Uninstaller.showCleanupFailure(error) }
        }
    }
}

struct MulgGameConditionalView: View {
    @Binding var selectedBackgroundColor: Color
    @Binding var selectedTextColor: Color
    @Binding var selected: MulgGame?
    @Binding var showStartingProgress: Bool

    @State var app: MulgGame
    @State var appIcon: NSImage?
    @State var isList: Bool
    @State var hasRuntime: Bool?
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isList {
                HStack(alignment: .center, spacing: 0) {
                    Group {
                        if let image = appIcon {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } else {
                            Rectangle()
                                 .fill(.regularMaterial)
                                 .overlay {
                                     ProgressView()
                                         .progressViewStyle(.circular)
                                         .controlSize(.small)
                                 }
                        }
                    }
                    .frame(width: 30, height: 30)
                    .cornerRadius(7.5)
                    .shadow(radius: 1)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 5)

                    Text(app.name)
                        .fontWeight(selected?.url == app.url ? .semibold : .regular)
                        .foregroundStyle(selected?.url == app.url ? AnyShapeStyle(MulgStyle.accent) : AnyShapeStyle(.primary))
                    if !(hasRuntime ?? true) {
                        Image(systemName: "exclamationmark.triangle")
                            .padding(.leading, 15)
                            .help("settings.noMulgKit")
                    }
                    if showStartingProgress {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 30, height: 30)
                    }
                    Spacer()
                    Text(app.settings.info.bundleVersion)
                        .padding(.horizontal, 15)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
                .background {
                    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                    if selected?.url == app.url {
                        shape.fill(MulgStyle.accent.opacity(0.13))
                    } else if hovering {
                        shape.fill(.primary.opacity(0.05))
                    }
                }
                .onHover { hovering = $0 }
            } else {
                // A card: icon, name, and an accent ring when selected (2026-10-10 redesign). A plain VStack:
                // each tile used to wrap itself in a LazyVStack, a lazy list container, for nothing.
                let isSelected = selected?.url == app.url
                VStack(spacing: 10) {
                    Group {
                        if let image = appIcon {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } else {
                            RoundedRectangle(cornerRadius: 21, style: .continuous)
                                .fill(.quaternary)
                                .overlay { ProgressView().controlSize(.small) }
                        }
                    }
                    .frame(width: 92, height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 21, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(hovering ? 0.32 : 0.16), radius: hovering ? 14 : 5, y: hovering ? 8 : 2)
                    .overlay(alignment: .topTrailing) {
                        if showStartingProgress {
                            ProgressView().controlSize(.small)
                                .padding(4).background(.regularMaterial, in: Circle()).offset(x: 6, y: -6)
                        } else if !(hasRuntime ?? true) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                                .padding(5).background(.regularMaterial, in: Circle()).offset(x: 6, y: -6)
                                .help("settings.noMulgKit")
                        }
                    }
                    Text(app.name)
                        .font(.callout.weight(isSelected ? .semibold : .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(height: 36, alignment: .top)
                        .foregroundStyle(isSelected ? AnyShapeStyle(MulgStyle.accent) : AnyShapeStyle(.primary))
                }
                .padding(.top, 14).padding(.horizontal, 10).padding(.bottom, 6)
                .frame(width: 148)
                .background {
                    let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
                    if isSelected {
                        shape.fill(MulgStyle.accent.opacity(0.12))
                            .overlay(shape.strokeBorder(MulgStyle.accent.opacity(0.75), lineWidth: 1.5))
                    } else if hovering {
                        shape.fill(.primary.opacity(0.06))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .scaleEffect(hovering && !reduceMotion ? 1.03 : 1)
                .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: hovering)
                .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isSelected)
                .onHover { hovering = $0 }
            }
        }
        .task(priority: .userInitiated) {
            let appURL = app.url
            let bundleIdentifier = app.info.bundleIdentifier
            let bundleVersion = app.info.bundleVersion
            let primaryIconName = app.info.primaryIconName
            let iconData = await Task.detached(priority: .utility) {
                Cacher.shared.resolveLocalIconData(
                    at: appURL,
                    bundleIdentifier: bundleIdentifier,
                    bundleVersion: bundleVersion,
                    primaryIconName: primaryIconName
                )
            }.value
            appIcon = iconData.flatMap(NSImage.init(data:))
        }
        .task(priority: .background) {
            hasRuntime = app.hasRuntime()
            showStartingProgress = app.isStarting
        }
    }
}
