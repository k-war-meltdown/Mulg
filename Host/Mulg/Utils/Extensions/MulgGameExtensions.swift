//
//  MulgGameExtensions.swift
//  Mulg
//
//  Created by TheMoonThatRises on 10/2/23.
//

import Foundation
import MulgLibrary

extension MulgGame {
    func loadDiscordIPC() {
        if self.container.doesExist() {
            let appTmp = self.container.containerUrl.appendingPathComponent("Data")
                .appendingPathComponent("tmp")

            try? FileManager.default.createDirectory(at: appTmp, withIntermediateDirectories: false)

            appTmp.enumerateContents { url, _ in
                if url.lastPathComponent.range(of: "discord-ipc-[0-9]", options: .regularExpression) != nil {
                    do {
                        try FileManager.default.removeItem(at: url)
                    } catch {
                        print("failed to remove discord ipc: \(error)")
                    }
                }
            }

            guard self.settings.settings.discordActivity.enable else {
                return
            }

            let userTmp = FileManager.default.temporaryDirectory.path

            for ipcPort in 0..<10 {
                let socketPath = userTmp + "/discord-ipc-\(ipcPort)"
                if FileManager.default.fileExists(atPath: socketPath) {
                    do {
                        try FileManager.default.createSymbolicLink(atPath: appTmp
                            .appendingPathComponent("discord-ipc-\(ipcPort)").path,
                                                                   withDestinationPath: socketPath)
                        print("Successfully linked discordipc for \(self.info.bundleIdentifier)")
                        return
                    } catch {
                        print(error)
                        continue
                    }
                }
            }

            print("Unable to link discordipc for \(self.info.bundleIdentifier)")
        }
    }

    func createAlias(for registeredApplication: URL? = nil) {
        do {
            // Never overwrite an unrelated app or a shortcut we could not retire.
            guard (try? FileManager.default.attributesOfItem(atPath: aliasURL.path)) == nil else { return }
            try FileManager.default.createDirectory(atPath: aliasURL.deletingLastPathComponent().path,
                                                    withIntermediateDirectories: true,
                                                    attributes: nil)
            // A linked copy of an app's contents is a second, invalid signed bundle.
            // A Finder bookmark is a shortcut to the one real application instead.
            let application = try registeredApplication ?? GameApplicationRegistration.register(url,
                bundleIdentifier: info.bundleIdentifier)
            let bookmark = try application.bookmarkData(options: .suitableForBookmarkFile,
                includingResourceValuesForKeys: nil, relativeTo: nil)
            try URL.writeBookmarkData(bookmark, to: aliasURL)
        } catch {
            Log.shared.log(error.localizedDescription)
        }
    }

    func removeAlias() {
        // Older versions registered a directory containing a copied Info.plist and
        // symlinked executable/resources. Retire that exact generated record first.
        guard let resources = try? aliasURL.resourceValues(forKeys: [.isDirectoryKey, .isAliasFileKey, .isSymbolicLinkKey]) else { return }
        if resources.isAliasFile == true {
            FileManager.default.delete(at: aliasURL)
            return
        }
        if resources.isDirectory == true {
            guard resources.isSymbolicLink != true,
                  let data = try? Data(contentsOf: aliasURL.appendingPathComponent("Info.plist")),
                  let metadata = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  metadata["CFBundleIdentifier"] as? String == info.bundleIdentifier,
                  let linked = try? FileManager.default.destinationOfSymbolicLink(atPath:
                    aliasURL.appendingPathComponent(info.executableName).path),
                  URL(fileURLWithPath: linked, relativeTo: aliasURL.appendingPathComponent("", isDirectory: true))
                    .resolvingSymlinksInPath() == executable.resolvingSymlinksInPath() else {
                Log.shared.log("Preserving an unrecognized application at the game shortcut path: \(aliasURL.path)")
                return
            }
            do { try GameApplicationRegistration.unregisterShadow(aliasURL) }
            catch { Log.shared.log("Could not retire the old game shortcut registration: \(error)") }
        } else {
            // Current shortcuts are Finder alias files. Other files belong to the user.
            return
        }
        FileManager.default.delete(at: aliasURL)
    }
}
