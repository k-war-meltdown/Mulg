//
//  SystemConfig.swift
//  Mulg
//

import Foundation

class SystemConfig {
    nonisolated(unsafe) static var isFirstTimeMulgSign = false

    static let isMulgSignActive: Bool = isSIPDisabled() && isRunningAMFIEnabled()

    static func enableMulgSign(_ argc: String) -> Bool {
        Shell.runSu([
            "-S",
            "/usr/sbin/nvram",
            "boot-args=" + mulgSignBootArgs(current: currentBootArgs())
        ], argc)
    }

    /// The Mac's boot-args now ("" when none are set). `nvram boot-args` prints "boot-args<TAB><value>".
    static func currentBootArgs() -> String {
        guard let output = try? Shell.run(print: false, "/usr/sbin/nvram", "boot-args"),
              let tab = output.firstIndex(of: "\t") else { return "" }
        return output[output.index(after: tab)...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The existing boot-args with MulgSign's two options set: the player's other options are kept (setting
    /// boot-args replaces all of them), and an existing value of either option is replaced, not doubled.
    static func mulgSignBootArgs(current: String) -> String {
        let required = ["amfi_get_out_of_my_way": "0x1", "ipc_control_port_options": "0"]
        let kept = current.split(whereSeparator: \.isWhitespace).map(String.init).filter { argument in
            !required.keys.contains(String(argument.split(separator: "=", maxSplits: 1).first ?? ""))
        }
        return (kept + required.keys.sorted().map { "\($0)=\(required[$0] ?? "")" }).joined(separator: " ")
    }

    static func isSIPDisabled() -> Bool {
        do {
            let check = try Shell.run("/usr/bin/csrutil", "status")
            return check.contains("unknown") || check.contains("disabled")
        } catch {
            return false
        }
    }

    static func isPRAMValid() -> Bool {
        do {
            let check = try Shell.run("/usr/sbin/nvram", "boot-args")
            for option in NVRAM_OPTIONS where check.contains(option) {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    static func isRunningAMFIEnabled() -> Bool {
        do {
            let check = try Shell.run("/usr/sbin/sysctl", "kern.bootargs")
            for option in NVRAM_OPTIONS where check.contains(option) {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    private static let NVRAM_OPTIONS = [
        "amfi_get_out_of_my_way=1",
        "amfi_get_out_of_my_way=0x1",
        "amfi_get_out_of_my_way=1 ipc_control_port_options=0",
        "amfi_get_out_of_my_way=0x1 ipc_control_port_options=0"
    ]
}
