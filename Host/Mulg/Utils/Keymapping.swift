//
//  Keymapping.swift
//  Mulg
//
//  Created by TheMoonThatRises on 9/15/25.
//

import AppKit
import Foundation
import MulgContracts
import UniformTypeIdentifiers

class Keymapping: @unchecked Sendable {
    static var keymappingDir: URL {
        let keymappingFolder = GameRuntime.mulgContainer.appendingPathComponent("Keymapping")
        if !FileManager.default.fileExists(atPath: keymappingFolder.path) {
            do {
                try FileManager.default.createDirectory(at: keymappingFolder,
                                                        withIntermediateDirectories: true,
                                                        attributes: [:])
            } catch {
                Log.shared.error(error)
            }
        }
        return keymappingFolder
    }

    let info: AppInfo
    let baseKeymapURL: URL
    let configURL: URL

    let encoder: PropertyListEncoder
    private var store: KeymapStore { KeymapStore(folder: baseKeymapURL, bundleIdentifier: info.bundleIdentifier) }

    var configNeedsRepair: Bool {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return false }
        if case .failure = store.readConfig() { return true }
        return false
    }

    var keymapConfig: KeymapConfig {
        get {
            if case .success(let config) = store.readConfig() {
                return KeymapConfig(defaultKm: constructKeymapPath(name: config.defaultKm.deletingPathExtension().lastPathComponent),
                                    keymapOrder: config.keymapOrder.map { constructKeymapPath(name: $0.deletingPathExtension().lastPathComponent) })
            }
            // A readable in-memory list does not replace a damaged file.
            let files = store.orderedKeymapFiles()
            return KeymapConfig(defaultKm: files.first ?? constructKeymapPath(name: "default"), keymapOrder: files)
        }
        set {
            if let problem = store.writeConfig(MulgContracts.KeymapConfig(defaultKm: newValue.defaultKm, keymapOrder: newValue.keymapOrder)) {
                Log.shared.error(problem)
            }
        }
    }

    init(_ info: AppInfo) {
        self.info = info

        self.baseKeymapURL = Keymapping.keymappingDir.appendingPathComponent(info.bundleIdentifier)
        self.configURL = baseKeymapURL.appendingPathComponent(".config").appendingPathExtension("plist")

        if !FileManager.default.fileExists(atPath: self.baseKeymapURL.path) {
            do {
                try FileManager.default.createDirectory(at: self.baseKeymapURL,
                                                        withIntermediateDirectories: true)
            } catch {
                Log.shared.error(error)
            }
        }

        self.encoder = PropertyListEncoder()
        self.encoder.outputFormat = .xml

        self.reloadKeymapCache()

    }

    private func constructKeymapPath(name: String) -> URL {
        baseKeymapURL.appendingPathComponent(name).appendingPathExtension("plist")
    }

    public func reloadKeymapCache() {
        let loaded = store.loadDefault()
        if let problem = loaded.problems.first { Log.shared.error(problem) }
        guard !configNeedsRepair else { return }
        // Include newly imported files without inventing empty replacements for missing maps.
        if case .success(var config) = store.readConfig() {
            config.defaultKm = store.keymapFile(named: config.defaultKm.deletingPathExtension().lastPathComponent)
            config.keymapOrder = config.keymapOrder.map { store.keymapFile(named: $0.deletingPathExtension().lastPathComponent) }
            for file in store.orderedKeymapFiles() where !config.keymapOrder.contains(file) {
                config.keymapOrder.append(file)
            }
            if let problem = store.writeConfig(config) { Log.shared.error(problem) }
        }
    }

    public func getKeymap(name: String) -> Keymap {
        let loaded = store.load(constructKeymapPath(name: name))
        if let problem = loaded.problems.first {
            Log.shared.error(problem)
            return Keymap(bundleIdentifier: info.bundleIdentifier)
        }
        do {
            let data = try Data(contentsOf: constructKeymapPath(name: name))
            let map = try PropertyListDecoder().decode(Keymap.self, from: data)
            return map
        } catch {
            Log.shared.error(error)
            return Keymap(bundleIdentifier: info.bundleIdentifier)
        }
    }

    public func createEmptyKeymap(name: String) -> Bool {
        guard !keymapFileExists(name: name) else { return false }
        setKeymap(name: name, map: Keymap(bundleIdentifier: info.bundleIdentifier))

        return hasKeymap(name: name)
    }

    /// `raw` writes the file as it came, keeping the keys this schema does not know
    /// (mulgAspectRatio, mulgLayers, mulgControllerBindings).
    private func setKeymap(name: String, map: Keymap, raw: Data? = nil) {
        let keymapPath = constructKeymapPath(name: name)

        do {
            let data = try raw ?? encoder.encode(map)
            try data.write(to: keymapPath, options: .atomic)

            if !keymapConfig.keymapOrder.contains(keymapPath) {
                keymapConfig.keymapOrder.append(keymapPath)
            }
        } catch {
            print(error)
        }
    }

    public func renameKeymap(prevName: String, newName: String) -> Bool {
        let oldPath = constructKeymapPath(name: prevName)
        let newPath = constructKeymapPath(name: newName)

        if let oldKeymapIndex = keymapConfig.keymapOrder.firstIndex(of: oldPath) {
            do {
                try FileManager.default.moveItem(at: oldPath, to: newPath)

                keymapConfig.keymapOrder[oldKeymapIndex] = newPath
                // A renamed default stays the default instead of pointing at a missing file.
                if keymapConfig.defaultKm == oldPath { keymapConfig.defaultKm = newPath }

                return true
            } catch {
                Log.shared.error(error)
                return false
            }
        } else {
            print("could not find keymap with name: \(prevName)")
            return false
        }
    }

    /// A copy to start a custom keymap from, byte for byte, so the recorded screen shape,
    /// layers and controller bindings come along.
    public func duplicateKeymap(name: String, newName: String) -> Bool {
        guard let data = try? Data(contentsOf: constructKeymapPath(name: name)) else { return false }
        guard !keymapFileExists(name: newName) else { return false }
        setKeymap(name: newName, map: Keymap(bundleIdentifier: info.bundleIdentifier), raw: data)
        return hasKeymap(name: newName)
    }

    public func deleteKeymap(name: String) -> Bool {
        let keymapURL = constructKeymapPath(name: name)

        if let keymapIndex = keymapConfig.keymapOrder.firstIndex(of: keymapURL) {
            do {
                try FileManager.default.trashItem(at: keymapURL, resultingItemURL: nil)

                keymapConfig.keymapOrder.remove(at: keymapIndex)

                return true
            } catch {
                Log.shared.error(error)
                return false
            }
        } else {
            print("could not find keymap with name: \(name)")
            return false
        }
    }

    /// A file of that name is already on disk. Unlike `hasKeymap` this is case-insensitive on a
    /// case-insensitive volume and sees files missing from the list, so a new profile never overwrites one.
    private func keymapFileExists(name: String) -> Bool {
        FileManager.default.fileExists(atPath: constructKeymapPath(name: name).path)
    }

    public func hasKeymap(name: String) -> Bool {
        keymapConfig.keymapOrder.contains(constructKeymapPath(name: name))
    }

    @discardableResult
    public func reset(name: String) -> Keymap {
        setKeymap(name: name, map: Keymap(bundleIdentifier: info.bundleIdentifier))
        return getKeymap(name: name)
    }

    /// Explicit repair keeps every map and rebuilds only the unreadable list.
    public func repairConfig() -> Bool {
        let files = store.orderedKeymapFiles()
        let config = MulgContracts.KeymapConfig(defaultKm: files.first ?? constructKeymapPath(name: "default"), keymapOrder: files)
        if let problem = store.writeConfig(config, replacingUnreadable: true) {
            Log.shared.error(problem)
            return false
        }
        return true
    }

    @MainActor public func importKeymap(name: String, success: @escaping (Bool) -> Void) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = true
        // Community keymaps still use the older playmap extension; the file format is the same.
        openPanel.allowedContentTypes = [UTType(exportedAs: "io.mulg.Mulg-mulgmap")]
            + [UTType(filenameExtension: "playmap")].compactMap { $0 }
        openPanel.title = NSLocalizedString("mulggame.importKm", comment: "")
        let sourceShape = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 140, height: 26))
        sourceShape.addItems(withTitles: ["16:9", "16:10", "21:9", "4:3"])
        let sourceAspects = [16.0 / 9, 16.0 / 10, 21.0 / 9, 4.0 / 3]
        let layoutControls = NSStackView(views: [NSTextField(labelWithString: "Source map shape:"), sourceShape,
            NSTextField(labelWithString: "Used when the file has no recorded shape."),
            NSTextField(labelWithString: "Creates adaptive 16:10, 16:9 and 21:9 layouts.")])
        layoutControls.orientation = .vertical
        layoutControls.alignment = .leading
        layoutControls.spacing = 6
        layoutControls.setFrameSize(layoutControls.fittingSize)
        openPanel.accessoryView = layoutControls

        openPanel.begin { result in
            if result == .OK {
                do {
                    if let selectedPath = openPanel.url {
                        let data = try Data(contentsOf: selectedPath)
                        let importedKeymap = try PropertyListDecoder().decode(Keymap.self, from: data)
                        let adaptive = try AdaptiveKeymapImport.prepare(data,
                            sourceAspect: sourceAspects[max(0, sourceShape.indexOfSelectedItem)],
                            bundleIdentifier: self.info.bundleIdentifier)
                        if importedKeymap.bundleIdentifier == self.info.bundleIdentifier {
                            self.setKeymap(name: name, map: importedKeymap, raw: adaptive)
                            success(true)
                        } else {
                            if self.differentBundleIdKeymapAlert() {
                                self.setKeymap(name: name, map: importedKeymap, raw: adaptive)
                                success(true)
                            } else {
                                success(false)
                            }
                        }
                    }
                } catch let error as CocoaError where error.code == .coderInvalidValue {
                    Log.shared.error(error)
                    success(false)
                } catch {
                    if let selectedPath = openPanel.url {
                        if let keymap = LegacySettings.convertLegacyKeymapFile(selectedPath) {
                            let encoder = PropertyListEncoder()
                            let encoded = try? encoder.encode(keymap)
                            guard let encoded, let adaptive = try? AdaptiveKeymapImport.prepare(encoded,
                                sourceAspect: sourceAspects[max(0, sourceShape.indexOfSelectedItem)],
                                bundleIdentifier: self.info.bundleIdentifier) else {
                                success(false)
                                return
                            }
                            if keymap.bundleIdentifier == self.info.bundleIdentifier {
                                self.setKeymap(name: name, map: keymap, raw: adaptive)
                                success(true)
                            } else {
                                if self.differentBundleIdKeymapAlert() {
                                    self.setKeymap(name: name, map: keymap, raw: adaptive)
                                    success(true)
                                } else {
                                    success(false)
                                }
                            }
                        } else {
                            success(false)
                        }
                    }
                }
                openPanel.close()
            }
        }
    }

    @MainActor public func exportKeymap(name: String) {
        let savePanel = NSSavePanel()
        savePanel.title = NSLocalizedString("mulggame.exportKm", comment: "")
        savePanel.nameFieldLabel = NSLocalizedString("mulggame.exportKmPanel.fieldLabel", comment: "")
        savePanel.nameFieldStringValue = info.displayName
        savePanel.allowedContentTypes = [UTType(exportedAs: "io.mulg.Mulg-mulgmap")]
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false

        savePanel.begin { result in
            if result == .OK {
                do {
                    if let selectedPath = savePanel.url {
                        // The file as it is, so the fork keys travel with the export.
                        let data = try Data(contentsOf: self.constructKeymapPath(name: name))
                        try data.write(to: selectedPath)
                        selectedPath.openInFinder()
                    }
                } catch {
                    savePanel.close()
                    Log.shared.error(error)
                }
                savePanel.close()
            }
        }
    }

    @MainActor private func differentBundleIdKeymapAlert() -> Bool {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("alert.differentBundleIdKeymap.message", comment: "")
        alert.informativeText = NSLocalizedString("alert.differentBundleIdKeymap.text", comment: "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("button.Proceed", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("button.Cancel", comment: ""))

        return alert.runModal() == .alertFirstButtonReturn
    }
}
