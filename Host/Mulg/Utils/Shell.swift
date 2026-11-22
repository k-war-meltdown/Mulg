//
//  Shell.swift
//  Mulg
//

import AppKit
import Foundation
import MulgLibrary

class Shell: ObservableObject {
    @discardableResult
    static func run(print: Bool = true, _ binary: String, _ args: String...) throws -> String {
        try run(print: print, binary, arguments: args)
    }

    @discardableResult
    static func run(print: Bool = true, _ binary: String, arguments args: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        let output = try pipe.fileHandleForReading.readToEnd() ?? Data()
        if print {
            Log.shared.log(String(data: output, encoding: .utf8) ?? "Shell error occured")
        }

        process.waitUntilExit()
        let status = process.terminationStatus
        if status != 0 {
            throw String(data: output, encoding: .utf8) ?? "Shell error occured"
        }
        return String(data: output, encoding: .utf8) ?? "Shell error occured"
    }

    static func runSu(_ args: [String], _ argc: String) -> Bool {
        let password = argc
        let passwordWithNewline = password + "\n"
        let sudo = Process()
        sudo.launchPath = "/usr/bin/sudo"
        sudo.arguments = args
        let sudoIn = Pipe()
        let sudoOut = Pipe()
        sudo.standardOutput = sudoOut
        sudo.standardError = sudoOut
        sudo.standardInput = sudoIn
        sudo.launch()

        nonisolated(unsafe) var result = true // Set by the output handler, read once it has seen EOF.
        let drained = DispatchSemaphore(value: 0)

        // Show the output as it is produced
        sudoOut.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                // EOF: without clearing the handler it fires again and again, spinning a core.
                fileHandle.readabilityHandler = nil
                drained.signal()
                return
            }

            if let out = String(bytes: data, encoding: .utf8) {
                Log.shared.log(out)
                if out.contains("password") {
                    result = false
                }
            }
        }
        if let data = passwordWithNewline.data(using: .utf8) {
            // Write the password
            sudoIn.fileHandleForWriting.write(data)

            // Close the file handle after writing the password; avoids a
            // hang for incorrect password.
            try? sudoIn.fileHandleForWriting.close()
        }

        // Make sure we don't disappear while output is still being produced.
        sudo.waitUntilExit()
        // The last output (a wrong-password message) may still be in the handler.
        _ = drained.wait(timeout: .now() + 2)
        return result && sudo.terminationStatus == 0
    }

    static func signMacho(_ binary: URL) throws {
        // Installs sign many binaries at once; Log is not thread-safe, so errors only.
        try run(print: false, "/usr/bin/codesign", "-fs-", binary.path)
    }

    /// Always ad hoc: a game's sandbox container only opens for the kind of signature that
    /// created it (see `Entitlements.isSignedByLocalIdentity`).
    static func signAppWith(_ exec: URL, entitlements: URL) throws {
        let app = exec.deletingLastPathComponent()
        let requirement = StableSigning.requirementArguments(bundleIdentifier: StableSigning.bundleIdentifier(ofApp: app))
        try run("/usr/bin/codesign", arguments: ["-fs-"] + requirement + [app.path, "--entitlements", entitlements.path])
        GameRuntime.recordInjection(exec)
    }

    static func signApp(_ exec: URL, recordInjection: Bool = true) throws {
        let app = exec.deletingLastPathComponent()
        let requirement = StableSigning.requirementArguments(bundleIdentifier: StableSigning.bundleIdentifier(ofApp: app))
        try run("/usr/bin/codesign", arguments: ["-fs-"] + requirement + [app.path, "--preserve-metadata=entitlements"])
        if recordInjection { GameRuntime.recordInjection(exec) }
    }

    @MainActor
    static func lldb(_ url: URL, withTerminalWindow: Bool = false, environment: [String: String]) async throws {
        if withTerminalWindow {
            let removed = ProcessInfo.processInfo.environment.keys.filter { environment[$0] == nil }.sorted()
            func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let command = "/usr/bin/env " + removed.map { "-u " + quote($0) }.joined(separator: " ")
                + " " + environment.filter { ProcessInfo.processInfo.environment[$0.key] != $0.value }
                    .sorted { $0.key < $1.key }.map { quote($0.key + "=" + $0.value) }.joined(separator: " ")
                + " /usr/bin/lldb -o run " + quote(url.path) + " -o exit"
            // Terminal opens a .command file like any document, so no Apple Events (Automation)
            // permission is needed; `do script` failed with -1743 whenever macOS had not granted
            // it, which every ad-hoc rebuild resets. The script removes itself before lldb starts.
            let script = FileManager.default.temporaryDirectory
                .appendingPathComponent("Mulg-LLDB-\(UUID().uuidString).command")
            do {
                try Data("#!/bin/zsh\nrm -f -- \"$0\"\nexec \(command)\n".utf8).write(to: script, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            } catch {
                throw "Cannot prepare the Terminal debugger launch: \(error.localizedDescription)"
            }
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                try? FileManager.default.removeItem(at: script)
                throw "Terminal is not available to run the debugger"
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            do {
                _ = try await NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: configuration)
            } catch {
                try? FileManager.default.removeItem(at: script)
                throw "Terminal could not open the debugger: \(error.localizedDescription)"
            }
        } else {
            let output = try await Task.detached(priority: .utility) {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/lldb")
                process.arguments = ["-b", "-o", "run", url.path, "-o", "exit"]
                process.environment = environment
                process.standardOutput = pipe
                process.standardError = pipe
                try process.run()
                var data = Data()
                var truncated = false
                while let chunk = try pipe.fileHandleForReading.read(upToCount: 16 * 1024), !chunk.isEmpty {
                    data.append(chunk)
                    if data.count > 64 * 1024 {
                        data.removeFirst(data.count - 64 * 1024)
                        truncated = true
                    }
                }
                process.waitUntilExit()
                let output = (truncated ? "Debugger output (last 64 KiB):\n" : "") + String(decoding: data, as: UTF8.self)
                guard process.terminationStatus == 0 else { throw output }
                return output
            }.value
            Log.shared.log(output)
        }
    }
}

extension Swift.String: Swift.Error { }

extension Swift.String: Foundation.LocalizedError {
    public var errorDescription: String? { self }
}
