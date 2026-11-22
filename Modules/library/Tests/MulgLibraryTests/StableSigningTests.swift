import Foundation
import Testing
@testable import MulgLibrary

@Suite("Stable signing requirement")
struct StableSigningTests {
    @Test func requirementNamesTheBundleIdentifier() {
        #expect(StableSigning.requirementArguments(bundleIdentifier: "com.miHoYo.GenshinImpact")
                == ["-r=designated => identifier \"com.miHoYo.GenshinImpact\""])
        // Anything codesign could misread gets no requirement (plain ad hoc, as before).
        #expect(StableSigning.requirementArguments(bundleIdentifier: "bad\" or anchor apple") == [])
        #expect(StableSigning.requirementArguments(bundleIdentifier: nil) == [])
        #expect(StableSigning.requirementArguments(bundleIdentifier: "") == [])
    }

    @Test func readsTheIdentifierFromEitherBundleLayout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ios = root.appendingPathComponent("Game.app"), mac = root.appendingPathComponent("Mac.app/Contents")
        for (folder, identifier) in [(ios, "com.example.ios"), (mac, "com.example.mac")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier], format: .xml, options: 0)
            try plist.write(to: folder.appendingPathComponent("Info.plist"))
        }
        #expect(StableSigning.bundleIdentifier(ofApp: ios) == "com.example.ios")
        #expect(StableSigning.bundleIdentifier(ofApp: root.appendingPathComponent("Mac.app")) == "com.example.mac")
        #expect(StableSigning.bundleIdentifier(ofApp: root) == nil)
    }
}
