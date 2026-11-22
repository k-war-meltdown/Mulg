#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
import Foundation
import MulgContracts
import Testing
@testable import MulgLibrary

@Suite("Launch-only desktop resolution")
struct DesktopLaunchResolutionTests {
    private func withStore(_ body: (SettingsStore, String) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try body(SettingsStore(paths: ContainerPaths(home: home)), "com.test.launch.display")
    }

    @Test func detectsDifferentDesktopSizesAndScalesWithoutHardcodedResolution() throws {
        for (width, height, scale, pixelWidth, pixelHeight) in [
            (1920.0, 1080.0, 1.0, 1920, 1080), (1920, 1080, 2, 3840, 2160),
            (2560, 1440, 2, 5120, 2880), (3440, 1440, 1, 3440, 1440),
            (1080, 1920, 1, 1080, 1920), (1440, 900, 2, 2880, 1800)
        ] {
            try withStore { store, id in
                let snapshot = try #require(DesktopLaunchResolution.Snapshot(size: CGSize(width: width, height: height), scale: scale))
                #expect(try DesktopLaunchResolution.prepare(for: id, snapshot: snapshot, store: store))
                let settings = store.load(bundleIdentifier: id).settings
                #expect(settings.fixedRenderSize?.width == pixelWidth)
                #expect(settings.fixedRenderSize?.height == pixelHeight)
            }
        }
    }

    @Test func onlyRefreshesTheThreeGeometryFieldsAndOnlyWhenCalledForAnotherLaunch() throws {
        try withStore { store, id in
            var settings = GameSettings(bundleIdentifier: id)
            settings.mulg.display.frameRateCap = 90
            settings.sensitivity = 81
            try store.save(settings)
            let file = store.paths.settingsFile(for: id)
            var original = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
            original["futureExtension"] = ["preserve": true]
            var mulg = original["mulg"] as! [String: Any]
            mulg["controls"] = ["playMode": "future-mode", "unknown": "preserve"]
            original["mulg"] = mulg
            try PropertyListSerialization.data(fromPropertyList: original, format: .xml, options: 0).write(to: file)
            let first = try #require(DesktopLaunchResolution.Snapshot(size: CGSize(width: 1920, height: 1080), scale: 1))
            #expect(try DesktopLaunchResolution.prepare(for: id, snapshot: first, store: store))
            let frozen = try Data(contentsOf: file)
            let laterDisplay = try #require(DesktopLaunchResolution.Snapshot(size: CGSize(width: 2560, height: 1440), scale: 2))
            // Capturing/changing a display has no side effects. The host must explicitly prepare a new launch.
            #expect(try Data(contentsOf: file) == frozen)
            #expect(!(try DesktopLaunchResolution.prepare(for: id, snapshot: first, store: store)))
            #expect(try Data(contentsOf: file) == frozen)
            #expect(try DesktopLaunchResolution.prepare(for: id, snapshot: laterDisplay, store: store))
            var changed = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
            #expect(changed["windowWidth"] as? Int == 2560 && changed["windowHeight"] as? Int == 1440)
            #expect(changed["customScaler"] as? Double == 2)
            for key in ["windowWidth", "windowHeight", "customScaler"] { original.removeValue(forKey: key); changed.removeValue(forKey: key) }
            #expect(changed as NSDictionary == original as NSDictionary)
        }
    }

    @Test func explicitPresetsAndUnavailableDisplaysLeaveSettingsByteForByteUnchanged() throws {
        try withStore { store, id in
            let screen = try #require(DesktopLaunchResolution.Snapshot(size: CGSize(width: 2560, height: 1440), scale: 2))
            for mode in ResolutionMode.allCases where mode != .display {
                var settings = GameSettings(bundleIdentifier: id)
                settings.resolution = mode.rawValue
                try store.save(settings)
                let before = try Data(contentsOf: store.paths.settingsFile(for: id))
                #expect(!(try DesktopLaunchResolution.prepare(for: id, snapshot: screen, store: store)))
                #expect(try Data(contentsOf: store.paths.settingsFile(for: id)) == before)
            }
            try store.save(GameSettings(bundleIdentifier: id))
            let before = try Data(contentsOf: store.paths.settingsFile(for: id))
            #expect(!(try DesktopLaunchResolution.prepare(for: id, snapshot: nil, store: store)))
            #expect(try Data(contentsOf: store.paths.settingsFile(for: id)) == before)
        }
    }

    @Test func invalidDisplayGeometryIsRejectedAndNotchSafeAreaUsesReportedInsets() throws {
        let safe = try #require(DesktopLaunchResolution.Snapshot(size: CGSize(width: 1512, height: 982), scale: 2, safeAreaTop: 37))
        #expect(safe.width == 1512 && safe.height == 945 && safe.scale == 2)
        for size in [CGSize.zero, CGSize(width: CGFloat.infinity, height: 900), CGSize(width: 900, height: CGFloat.nan),
                     CGSize(width: -1, height: 900), CGSize(width: 20000, height: 900)] {
            #expect(DesktopLaunchResolution.Snapshot(size: size, scale: 2) == nil)
        }
        for scale: CGFloat in [0, -1, .infinity, .nan, .greatestFiniteMagnitude] {
            #expect(DesktopLaunchResolution.Snapshot(size: CGSize(width: 1920, height: 1080), scale: scale) == nil)
        }
        #expect(DesktopLaunchResolution.Snapshot(size: CGSize(width: 1512, height: 982), scale: 2, safeAreaTop: 983) == nil)
    }

    @Test func corruptPreferencesAreReportedAndPreserved() throws {
        try withStore { store, id in
            try FileManager.default.createDirectory(at: store.paths.appSettingsDirectory, withIntermediateDirectories: true)
            let file = store.paths.settingsFile(for: id), corrupt = Data("not a plist".utf8)
            try corrupt.write(to: file)
            let screen = try #require(DesktopLaunchResolution.Snapshot(size: CGSize(width: 1920, height: 1080), scale: 1))
            #expect(throws: (any Error).self) { try DesktopLaunchResolution.prepare(for: id, snapshot: screen, store: store) }
            #expect(try Data(contentsOf: file) == corrupt)
        }
    }

    @MainActor @Test func readsTheCurrentMacDisplayOnlyWhenPreparingALaunch() throws {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let expected = DesktopLaunchResolution.Snapshot(size: screen.frame.size, scale: screen.backingScaleFactor,
                                                              safeAreaTop: screen.safeAreaInsets.top) else { return }
        try withStore { store, id in
            let prepared = try DesktopLaunchResolution.prepare(for: id, store: store)
            #expect(prepared)
            let actual = store.load(bundleIdentifier: id).settings
            #expect(actual.windowWidth == expected.width && actual.windowHeight == expected.height)
            #expect(actual.customScaler == expected.scale)
        }
    }
}
#endif
