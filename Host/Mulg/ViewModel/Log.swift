//
//  Log.swift
//  Mulg
//

import Foundation
import SwiftUI

// ponytail: unchecked, logdata is appended from any thread like before; add a lock if log lines ever interleave.
class Log: ObservableObject, @unchecked Sendable {

    static let shared = Log()

    func error(_ err: Error) {
        Task { @MainActor in
            self.dialog(
                question: NSLocalizedString("alert.error", comment: ""),
                text: err.localizedDescription,
                style: NSAlert.Style.critical)
        }
    }

    func error(localized str: String, args: [String] = []) {
        error(String(format: NSLocalizedString(str, comment: ""), arguments: args))
    }

    func msg(_ msg: String) {
        Task { @MainActor in
            self.log(msg)
            self.dialog(
                question: NSLocalizedString("alert.success", comment: ""),
                text: msg,
                style: NSAlert.Style.informational)
        }
    }

    var logdata = "\(ProcessInfo.processInfo.operatingSystemVersionString)\n"

    func log(_ str: String, isError: Bool = false) {
        print(str)
        if isError {
            logdata.append("ERROR: ")
        }
        logdata.append(str)
        logdata.append("\n")
    }

    @MainActor private func dialog(question: String, text: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = text
        alert.alertStyle = style
        alert.addButton(withTitle: NSLocalizedString("button.OK", comment: ""))
        alert.runModal()
    }

    required init() { }
}
