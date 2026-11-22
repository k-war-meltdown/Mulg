//
//  InstallSettings.swift
//  Mulg
//
//  Created by TheMoonThatRises on 10/9/22.
//

import MulgGUI
import SwiftUI

class InstallPreferences: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = InstallPreferences()

    @objc @AppStorage("AlwaysInstallMulgKit") var alwaysInstallMulgKit = true

    // Games by default: macOS Game Mode (CPU and GPU priority, double Bluetooth sampling for
    // controllers and AirPods) needs the Games category and engages only in full screen.
    @AppStorage("DefaultAppType") var defaultAppType: LSApplicationCategoryType = .games

    @AppStorage("ShowInstallPopup") var showInstallPopup = false

    @AppStorage("ShowAppStorePopup") var showAppStorePopup = true

    @AppStorage(GUIKey.askInstallFolder) var askInstallFolder = true

    @AppStorage(GUIKey.installFolder) var installFolder = ""

    var installFolderURL: URL {
        installFolder.isEmpty ? AppsVM.appDirectory : URL(fileURLWithPath: installFolder, isDirectory: true)
    }

    /// The folder for the next install: the saved one, or, when asking is on, the one the
    /// player picks (remembered for next time). Nil when they cancel.
    @MainActor func destinationForInstall() -> URL? {
        guard askInstallFolder else { return installFolderURL }
        guard let url = Self.pickFolder(startingAt: installFolderURL, prompt: "Install Here") else { return nil }
        installFolder = url.standardizedFileURL == AppsVM.appDirectory.standardizedFileURL ? "" : url.path
        return url
    }

    /// What goes into the folder, shown under the folder browser (2026-10-10: players did not know
    /// that in-game downloads also land there).
    static let folderExplanationText = """
        The game's files are stored in this folder:
        • the game itself
        • everything it downloads in the game (updates, extra content, voices)
        • its saves, caches and logs

        Only a few small macOS preferences stay in the system. To remove a game completely, uninstall it in \
        Mulg or delete its folder. If the folder is on an \
        external drive, keep that drive connected while you play.
        """

    @MainActor private static func folderExplanation() -> NSView {
        let text = NSTextField(wrappingLabelWithString: folderExplanationText)
        text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        text.textColor = .secondaryLabelColor
        text.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            text.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            text.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            text.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            text.widthAnchor.constraint(equalToConstant: 460)
        ])
        return container
    }

    @MainActor static func pickFolder(startingAt folder: URL, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = prompt
        panel.message = "Choose a folder for the game. Everything the game needs and downloads will be stored in it."
        panel.accessoryView = folderExplanation()
        panel.isAccessoryViewDisclosed = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct InstallSettings: View {
    public static var shared = InstallSettings()

    @ObservedObject var installPreferences = InstallPreferences.shared

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("settings.applicationCategoryType")
                Spacer()
                Picker("", selection: installPreferences.$defaultAppType) {
                    ForEach(LSApplicationCategoryType.allCases, id: \.rawValue) { value in
                        Text(value.localizedName)
                            .tag(value)
                    }
                }
                .frame(width: 225)
            }
            Spacer()
                .frame(height: 20)
            Toggle("preferences.toggle.showAppStorePopup", isOn: $installPreferences.showAppStorePopup)
            Spacer()
                .frame(height: 20)
            HStack {
                Text("Install games in")
                Spacer()
                Text(installPreferences.installFolder.isEmpty
                     ? "Mulg library" : (installPreferences.installFolder as NSString).abbreviatingWithTildeInPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose…") {
                    if let url = InstallPreferences.pickFolder(startingAt: installPreferences.installFolderURL,
                                                               prompt: "Choose") {
                        installPreferences.installFolder = url.path
                    }
                }
                Button("Use Library") { installPreferences.installFolder = "" }
                    .disabled(installPreferences.installFolder.isEmpty)
            }
            Toggle("Ask where to install when adding or dropping a game", isOn: $installPreferences.askInstallFolder)
            Spacer()
                .frame(height: 20)
            Text("Each game keeps all of its files in its install folder: the game, everything it downloads in-game, saves and caches. Uninstall in Mulg or delete the folder to remove it completely. Keep an external drive connected while playing.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 600, height: 270)
    }
}
