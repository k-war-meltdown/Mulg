//
//  MenuBarView.swift
//  Mulg
//

import AppKit
import SwiftUI
@preconcurrency import DataCache

struct MulgMenuView: Commands {
    @Binding var isSigningSetupShown: Bool
    var body: some Commands {
        CommandGroup(after: .systemServices) {
            Button("menubar.log.copy", systemImage: "document.on.document.fill") {
                Log.shared.logdata.copyToClipBoard()
            }
            .keyboardShortcut("L", modifiers: [.command, .option])
            Button("menubar.configSigning", systemImage: "signature") {
                isSigningSetupShown = true
            }
        }
    }
}

struct MulgHelpMenuView: Commands {
    @ObservedObject var updaterViewModel: UpdaterViewModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesView(updaterViewModel: updaterViewModel)
        }

        CommandGroup(replacing: .help) {
            // No community links: Mulg has no website, docs or chat yet.
            #if DEBUG
            Button("[DEBUG] Crash app", systemImage: "xmark.circle.fill") {
                fatalError("Crash was triggered")
            }
            #endif
        }
    }
}

struct MulgViewMenuView: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .importExport) {
            Button("menubar.exportToSideloady", systemImage: "square.and.arrow.up.fill") {
                Task {
                    if InstallVM.shared.inProgress {
                        Log.shared.error(MulgError.waitInstallation)
                    } else if DownloadVM.shared.inProgress {
                        Log.shared.error(MulgError.waitDownload)
                    } else {
                        // remove await for Swift 6 (no async operation occurs)
                        await NSOpenPanel.selectIPA { result in
                            if case .success(let url) = result {
                                Task { @MainActor in
                                    Installer.install(ipaUrl: url,
                                                            export: true,
                                                            returnCompletion: { ipa in
                                        Task { @MainActor in
                                            if let ipa = ipa {
                                                ipa.showInFinder()
                                                let config = NSWorkspace.OpenConfiguration()
                                                config.promptsUserIfNeeded = true
                                                let url = NSWorkspace.shared
                                                    .urlForApplication(withBundleIdentifier:
                                                                        "io.sideloadly.sideloadly")
                                                if let url = url {
                                                    NSWorkspace.shared
                                                        .open([ipa], withApplicationAt: url, configuration: config)
                                                } else {
                                                    Log.shared.error("Could not find Sideloadly!")
                                                }
                                            } else {
                                                Log.shared.error("Could not find file!")
                                            }
                                        }
                                    })
                                }
                            }
                        }
                    }
                }
            }
        }
        CommandGroup(before: .sidebar) {
            Button("menubar.clearCache", systemImage: "eraser.fill") {
                DataCache.instance.cleanAll()
                Cacher.shared.removeImageCache()

                if let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
                   let bundleID = Bundle.main.bundleIdentifier {
                    FileManager.default.delete(at: cacheDir.appendingPathComponent(bundleID)
                        .appendingPathComponent("Image Cache"))
                }
            }
            .keyboardShortcut("R", modifiers: [.command, .shift])
            Divider()
        }
    }
}
