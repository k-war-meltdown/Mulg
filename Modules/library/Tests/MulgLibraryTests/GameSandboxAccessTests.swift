#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import MulgContracts
@testable import MulgLibrary
import Testing

@Suite("Game sandbox access", .serialized)
struct GameSandboxAccessTests {
    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mulg-sandbox-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // The kernel matches real paths (/private/var/…); Foundation's symlink resolution strips /private.
        guard let real = realpath(url.path, nil) else { return url }
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real), isDirectory: true)
    }

    @Test("An IPA keeps no sandbox exception, file access or debugging right")
    func entitlementAllowList() {
        for key in ["com.apple.security.files.all",
                    "com.apple.security.temporary-exception.files.absolute-path.read-write",
                    "com.apple.security.temporary-exception.mach-lookup.global-name",
                    "com.apple.security.temporary-exception.sbpl", "com.apple.security.cs.disable-library-validation",
                    "get-task-allow", "keychain-access-groups", "com.apple.security.application-groups",
                    "com.apple.private.tcc.allow", "com.apple.developer.icloud-services", "com.apple.application-identifier"] {
            #expect(!BundleCapabilities.mayKeep(key), "\(key)")
        }
        // The explicit restricted mode keeps provisioning keys, never an escape.
        #expect(BundleCapabilities.mayKeep("com.apple.developer.icloud-services", allowRestricted: true))
        #expect(!BundleCapabilities.mayKeep("com.apple.security.files.all", allowRestricted: true))
        #expect(!BundleCapabilities.mayKeep("com.apple.security.app-sandbox", value: false, allowRestricted: true))
        #expect(BundleCapabilities.mayKeep("com.apple.security.app-sandbox", value: true))
        #expect(!BundleCapabilities.mayKeep("com.apple.security.app-sandbox", value: false))
        #expect(BundleCapabilities.mayKeep("com.apple.security.network.client", value: true))
        #expect(!BundleCapabilities.mayKeep("com.apple.security.files.bookmarks.app-scope", value: true))
        #expect(BundleCapabilities.mayKeep("UIBackgroundModes"))
    }

    @Test("Rules name only the game's own paths; a hostile identifier gets none")
    func rules() throws {
        let paths = ContainerPaths(home: try home())
        defer { try? FileManager.default.removeItem(at: paths.home) }
        let rules = try #require(GameSandboxAccess.sandboxRules(for: "com.example.game", paths: paths)).joined(separator: "\n")
        #expect(rules.contains("com\\.example\\.game\\.plist"))
        #expect(!rules.contains("(subpath \"\(paths.mulgContainer.path)\")"))
        #expect(GameSandboxAccess.sandboxRules(for: "../../etc", paths: paths) == nil)
        #expect(GameSandboxAccess.sandboxRules(for: "a\") (allow file* (subpath \"/", paths: paths) == nil)
        #expect(GameSandboxAccess.groupContainerRules(groups: ["group.com.example", "..", "a/b", "*"], home: paths.home).count == 2)
    }

    /// macOS itself: a process sandboxed with the game's rules reads and saves its own files and
    /// cannot read another game's login database or settings.
    @Test("macOS enforces the rules: own files work, another game's do not")
    func enforced() throws {
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ContainerPaths(home: root)
        let files = FileManager.default
        for id in ["com.example.game", "com.example.other"] {
            GameSandboxAccess.prepareFolders(for: id, paths: paths)
            try Data("secret".utf8).write(to: paths.mulgChainDatabase(for: id))
            try Data("settings".utf8).write(to: paths.settingsFile(for: id))
        }
        let rules = try #require(GameSandboxAccess.sandboxRules(for: "com.example.game", paths: paths))
        // Allow everything else, deny Mulg's folder, then the game's own grants (the last match wins).
        let profile = (["(version 1)", "(allow default)", "(deny file* (subpath \"\(paths.mulgContainer.path)\"))"] + rules)
            .joined(separator: "\n")
        let folder = root.appendingPathComponent("probe")
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("probe.c"), executable = folder.appendingPathComponent("probe")
        try Data(#"""
            #include <errno.h>
            #include <fcntl.h>
            #include <sys/stat.h>
            #include <sandbox.h>
            #include <stdio.h>
            #include <stdlib.h>
            #include <string.h>
            #include <unistd.h>
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            int main(int argc, char **argv) {
                FILE *f = fopen(argv[1], "r"); char profile[65536] = {0}; fread(profile, 1, sizeof profile - 1, f); fclose(f);
                char *error = NULL;
                if (sandbox_init(profile, 0, &error) != 0) { printf("profile-error %s\n", error); return 2; }
                for (int i = 2; i < argc; i++) {
                    if (argv[i][0] == 'd') {
                        int made = mkdir(argv[i] + 2, 0700) == 0 || errno == EEXIST;
                        printf("%s %s\n", made ? "ok" : "denied", argv[i]);
                        continue;
                    }
                    int write = argv[i][0] == 'w';
                    int fd = open(argv[i] + 2, write ? O_WRONLY | O_CREAT | O_TRUNC : O_RDONLY, 0644);
                    printf("%s %s\n", fd >= 0 ? "ok" : "denied", argv[i]);
                    if (fd >= 0) close(fd);
                }
                return 0;
            }
            """#.utf8).write(to: source)
        try Data(profile.utf8).write(to: folder.appendingPathComponent("profile.sb"))
        let compiled = try run("/usr/bin/xcrun", ["clang", source.path, "-o", executable.path])
        try #require(compiled.status == 0, Comment(rawValue: compiled.output))
        let own = paths.settingsFile(for: "com.example.game"), other = paths.settingsFile(for: "com.example.other")
        let checks = [
            "d:" + paths.mulgChainDirectory.path,                                    // make sure a shared folder exists
            "r:" + own.path,
            "w:" + own.path + ".sb-1234-abcd",                                     // an atomic save's temporary
            "r:" + paths.mulgChainDatabase(for: "com.example.game").path,
            "w:" + paths.diagnosticsDirectory(for: "com.example.game").appendingPathComponent("r.json").path,
            "w:" + paths.safeModeMarker(for: "com.example.game").path,
            "w:" + paths.safeModeMarker(for: "com.example.game").appendingPathExtension("last.json").path,
            "w:" + paths.safeModeMarker(for: "com.example.game").appendingPathExtension("last.json").path + ".sb-1234-abcd",
            "r:" + other.path,
            "r:" + paths.mulgChainDatabase(for: "com.example.other").path,
            "w:" + paths.diagnosticsDirectory(for: "com.example.other").appendingPathComponent("r.json").path,
            "w:" + paths.mulgChainDirectory.appendingPathComponent("planted.txt").path, // no new files in shared folders
            "w:" + paths.safeModeMarker(for: "com.example.other").appendingPathExtension("last.json").path,
            "w:" + paths.safeModeMarker(for: "com.example.game.extra").path,
            "w:" + paths.safeModeMarker(for: "com.example.game").path + ".ungranted",
        ]
        let result = try run(executable.path, [folder.appendingPathComponent("profile.sb").path] + checks)
        try #require(result.status == 0, Comment(rawValue: result.output))
        let lines = result.output.split(separator: "\n").map(String.init)
        #expect(lines.count == checks.count, Comment(rawValue: result.output))
        #expect(lines.prefix(8).allSatisfy { $0.hasPrefix("ok ") }, Comment(rawValue: result.output))
        #expect(lines.suffix(7).allSatisfy { $0.hasPrefix("denied ") }, Comment(rawValue: result.output))
    }

    @Test("The keychain wall: macOS refuses the game every Keychain item")
    func keychainWall() throws {
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("wall.c"), executable = root.appendingPathComponent("wall")
        // Counts login-keychain items by attributes only; never reads a secret.
        try Data(#"""
            #include <Security/Security.h>
            #include <sandbox.h>
            #include <stdio.h>
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            int main(int argc, char **argv) {
                if (argc > 1) {
                    FILE *f = fopen(argv[1], "r"); static char profile[65536]; fread(profile, 1, sizeof profile - 1, f); fclose(f);
                    char *error = NULL;
                    if (sandbox_init(profile, 0, &error) != 0) { printf("profile-error %s\n", error); return 2; }
                }
                const void *keys[] = { kSecClass, kSecMatchLimit, kSecReturnAttributes, kSecUseDataProtectionKeychain };
                const void *values[] = { kSecClassGenericPassword, kSecMatchLimitAll, kCFBooleanTrue, kCFBooleanFalse };
                CFDictionaryRef query = CFDictionaryCreate(NULL, keys, values, 4, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
                CFTypeRef result = NULL;
                OSStatus status = SecItemCopyMatching(query, &result);
                long count = result && CFGetTypeID(result) == CFArrayGetTypeID() ? CFArrayGetCount(result) : 0;
                printf("%d %ld\n", (int)status, count);
                return 0;
            }
            """#.utf8).write(to: source)
        let compiled = try run("/usr/bin/xcrun", ["clang", source.path, "-framework", "Security", "-framework", "CoreFoundation", "-o", executable.path])
        try #require(compiled.status == 0, Comment(rawValue: compiled.output))
        let profile = root.appendingPathComponent("wall.sb")
        try Data((["(version 1)", "(allow default)"] + GameSandboxAccess.keychainWallRules(home: ContainerPaths.realHomeDirectory()))
            .joined(separator: "\n").utf8).write(to: profile)
        let open = try run(executable.path, []), walled = try run(executable.path, [profile.path])
        let walledFields = walled.output.split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        try #require(walledFields.count == 2, Comment(rawValue: walled.output))
        #expect(walledFields[0] != "0" && walledFields[1] == "0", Comment(rawValue: "open: \(open.output) walled: \(walled.output)"))
    }

    @Test("A Keychain-held key gets one migration window; afterwards the wall is up and nothing is moved")
    func migrationWindow() throws {
        let paths = ContainerPaths(home: try home())
        defer { try? FileManager.default.removeItem(at: paths.home) }
        let id = "com.example.game", files = FileManager.default
        try files.createDirectory(at: paths.mulgChainDirectory, withIntermediateDirectories: true)
        let held: (String) -> Bool = { _ in true }
        #expect(!GameSandboxAccess.keychainMigrationLaunch(for: id, savesLogins: true, paths: paths, legacyKeyExists: held)) // no database
        try Data("db".utf8).write(to: paths.mulgChainDatabase(for: id))
        #expect(!GameSandboxAccess.keychainMigrationLaunch(for: id, savesLogins: false, paths: paths, legacyKeyExists: held))
        #expect(GameSandboxAccess.migrationState(for: id, savesLogins: true, paths: paths) == .notStarted)
        var now = Date.now
        #expect(GameSandboxAccess.keychainMigrationLaunch(for: id, savesLogins: true, paths: paths, now: now, legacyKeyExists: held))
        #expect(GameSandboxAccess.keychainMigrationLaunch(for: id, savesLogins: true, paths: paths, now: now, legacyKeyExists: held))
        #expect(GameSandboxAccess.migrationState(for: id, savesLogins: true, paths: paths, now: now) == .pending)
        // The key never arrived: the window closes, the database stays exactly where it is, and the move gets
        // another launch while the old key is still in the Keychain, up to three windows in all.
        for _ in 2...GameSandboxAccess.maxMigrationWindows {
            now += 601
            #expect(GameSandboxAccess.migrationState(for: id, savesLogins: true, paths: paths, now: now) == .notStarted)
            #expect(GameSandboxAccess.keychainMigrationLaunch(for: id, savesLogins: true, paths: paths, now: now, legacyKeyExists: held))
        }
        now += 601
        #expect(!GameSandboxAccess.keychainMigrationLaunch(for: id, savesLogins: true, paths: paths, now: now, legacyKeyExists: held))
        #expect(GameSandboxAccess.migrationState(for: id, savesLogins: true, paths: paths, now: now) == .stuck)
        #expect(try Data(contentsOf: paths.mulgChainDatabase(for: id)) == Data("db".utf8))
        // The key arrived: the wall is up for good.
        try Data("sealed".utf8).write(to: paths.mulgChainKey(for: id))
        #expect(!GameSandboxAccess.keychainMigrationLaunch(for: id, savesLogins: true, paths: paths, now: now, legacyKeyExists: held))
        #expect(GameSandboxAccess.migrationState(for: id, savesLogins: true, paths: paths) == .none)
        // The game deletes its own key file and the old record: the window never opens again.
        try files.removeItem(at: paths.mulgChainKey(for: id))
        try? files.removeItem(at: GameSandboxAccess.legacyMigrationMarker(for: id, paths: paths))
        #expect(!GameSandboxAccess.keychainMigrationLaunch(for: id, savesLogins: true, paths: paths, now: now, legacyKeyExists: held))
        #expect(GameSandboxAccess.migrationState(for: id, savesLogins: true, paths: paths, now: now) == .stuck)
    }

    @Test("A moved key leaves no Keychain item: a deleted key file reopens no window")
    func movedKeyNoNewWindow() throws {
        let paths = ContainerPaths(home: try home())
        defer { try? FileManager.default.removeItem(at: paths.home) }
        let id = "com.example.game", files = FileManager.default
        try files.createDirectory(at: paths.mulgChainDirectory, withIntermediateDirectories: true)
        try Data("db".utf8).write(to: paths.mulgChainDatabase(for: id))
        #expect(GameSandboxAccess.keychainMigrationLaunch(for: id, savesLogins: true, paths: paths, legacyKeyExists: { _ in true }))
        // The game moved the key (and the bridge deleted the Keychain item), then deletes its own key file.
        #expect(!GameSandboxAccess.keychainMigrationLaunch(for: id, savesLogins: true, paths: paths, now: .now + 601,
                                                            legacyKeyExists: { _ in false }))
        #expect(GameSandboxAccess.migrationState(for: id, savesLogins: true, paths: paths, now: .now + 601) == .stuck)
    }

    @Test("No older key in the Keychain: the window never opens, and its record is out of the game's reach")
    func noLegacyKeyNoWindow() throws {
        let paths = ContainerPaths(home: try home())
        defer { try? FileManager.default.removeItem(at: paths.home) }
        let id = "com.example.game", files = FileManager.default
        try files.createDirectory(at: paths.mulgChainDirectory, withIntermediateDirectories: true)
        try Data("db".utf8).write(to: paths.mulgChainDatabase(for: id))
        #expect(!GameSandboxAccess.keychainMigrationLaunch(for: id, savesLogins: true, paths: paths, legacyKeyExists: { _ in false }))
        #expect(GameSandboxAccess.migrationState(for: id, savesLogins: true, paths: paths) == .stuck)
        let rules = try #require(GameSandboxAccess.sandboxRules(for: id, paths: paths)).joined(separator: "\n")
        #expect(!rules.contains("KeychainMigration"))
    }

    @Test("Every game reaches the one shared audio-lock folder, at the path the bridge builds")
    func sharedAudioLocks() throws {
        let paths = ContainerPaths(home: try home())
        defer { try? FileManager.default.removeItem(at: paths.home) }
        let folder = paths.audioOutputLockDirectory.path
        // AudioOutputController.lockDirectory builds this literally (the bridge has no contracts import).
        #expect(folder == paths.home.path + "/Library/Containers/io.mulg.Mulg/Mulg/AudioOutput")
        for id in ["com.example.game", "com.example.other"] {
            let rules = try #require(GameSandboxAccess.sandboxRules(for: id, paths: paths)).joined(separator: "\n")
            #expect(rules.contains("(allow file* (subpath \"\(GameSandboxAccess.canonical(paths.audioOutputLockDirectory).path)\"))"))
        }
        GameSandboxAccess.prepareFolders(for: "com.example.game", paths: paths)
        #expect(FileManager.default.fileExists(atPath: folder))
    }

    @Test("A file grant names exactly the game's file, not every name that starts with it")
    func fileGrantsAreExact() throws {
        let paths = ContainerPaths(home: try home())
        defer { try? FileManager.default.removeItem(at: paths.home) }
        let rule = try #require(GameSandboxAccess.sandboxRules(for: "com.x", paths: paths)?.first { $0.contains("com\\.x\\.key") })
        let pattern = String(rule.split(separator: "#\"")[1].dropLast(3))
        let regex = try Regex(pattern)
        let key = paths.mulgChainKey(for: "com.x").path
        for allowed in [key, key + ".sb-1a2b3c4d-QZ1v3X", key + ".lock"] { #expect(allowed.wholeMatch(of: regex) != nil, "\(allowed)") }
        for other in [paths.mulgChainKey(for: "com.x.keyboard").path, key + "/x", key + "board"] {
            #expect(other.wholeMatch(of: regex) == nil, "\(other)")
        }
    }

    @Test("Logins locked by the Mulg vault wait for the unlock: the wall stays up, no window runs out")
    func lockedLoginsWait() throws {
        let paths = ContainerPaths(home: try home())
        defer { try? FileManager.default.removeItem(at: paths.home) }
        let id = "com.example.game", files = FileManager.default
        try files.createDirectory(at: paths.mulgChainDirectory, withIntermediateDirectories: true)
        let locked = paths.mulgChainDirectory.appendingPathComponent(id + "." + ContainerPaths.legacyVaultExtension)
        try Data("locked".utf8).write(to: locked)
        #expect(GameSandboxAccess.migrationState(for: id, savesLogins: true, paths: paths) == .waitingForUnlock)
        #expect(!GameSandboxAccess.keychainMigrationLaunch(for: id, savesLogins: true, paths: paths, now: .now + 3600, legacyKeyExists: { _ in true }))
        #expect(!files.fileExists(atPath: GameSandboxAccess.migrationMarker(for: id, paths: paths).path))
        // Unlocked: the database is back, and the window opens on the next launch.
        try files.moveItem(at: locked, to: paths.mulgChainDatabase(for: id))
        #expect(GameSandboxAccess.keychainMigrationLaunch(for: id, savesLogins: true, paths: paths, legacyKeyExists: { _ in true }))
    }

    private func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
#endif
