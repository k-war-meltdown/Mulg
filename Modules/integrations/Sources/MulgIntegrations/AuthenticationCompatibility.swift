import Foundation
import MulgContracts
import MulgEngine
import MulgIntegrationsHooks

/// Repairs native presentation and observes results without rewriting provider requests.
@MainActor
final class AuthenticationCompatibility {
    private weak var context: ModuleContext?
    private var report: LoginCompatibilityReport
    private var warnedAboutApple = false

    init(_ context: ModuleContext) {
        self.context = context
        let removed = (try? Data(contentsOf: Bundle.main.bundleURL.appendingPathComponent("MulgCapabilities.json")))
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        let unavailable = removed.contains { $0.hasSuffix(": com.apple.developer.applesignin") }
        let entries = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let schemes = Set(entries.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] })
        report = LoginCompatibilityReport(bundleIdentifier: context.bundleIdentifier,
            launchSessionID: context.launchSessionID,
            enabled: context.settings.mulg.integrations.authenticationCompatibility, removedAppleSignInCapability: unavailable,
            declaredCallbackSchemeCount: schemes.count, installedHooks: [])
    }

    func install() {
        guard report.enabled else { mulg_authentication_disable(); writeReport(); return }
        let installed = mulg_authentication_install({
            #if canImport(UIKit)
            MainActor.assumeIsolated { GameViewport.shared.window }
            #else
            nil // No game window outside Mac Catalyst (package tests).
            #endif
        }, { [weak self] provider, state, domain, code in
            MainActor.assumeIsolated { self?.receive(provider: provider, state: state, domain: domain, code: code) }
        })
        report = LoginCompatibilityReport(bundleIdentifier: report.bundleIdentifier,
            launchSessionID: report.launchSessionID, enabled: report.enabled, removedAppleSignInCapability: report.removedAppleSignInCapability,
            declaredCallbackSchemeCount: report.declaredCallbackSchemeCount, installedHooks: installed)
        if let context {
            for hook in installed { try? context.hooks.claim(hook, owner: .integrations, kind: .swizzle, privateAPI: false) }
        }
        writeReport()
    }

    private func receive(provider: String, state: String, domain: String?, code: Int) {
        guard let context else { return }
        report.append(.init(provider: provider, state: state, errorDomain: domain, errorCode: domain == nil ? nil : code))
        writeReport()
        if provider == "apple", report.removedAppleSignInCapability, state == "requested", !warnedAboutApple {
            warnedAboutApple = true
            context.notices.show(Notice("Apple sign-in needs publisher provisioning",
                lines: ["This converted game does not retain its publisher's Apple sign-in capability.",
                        "Use web sign-in or another login method if the game offers one."],
                style: .warning, duration: .seconds(8), important: true))
        }
        guard ["failed", "startRejected", "presentationFailed"].contains(state) else { return }
        let title = provider == "apple" ? "Apple sign-in failed" : "Game sign-in failed"
        let detail: String
        if provider == "apple", report.removedAppleSignInCapability {
            detail = "The publisher's Apple sign-in provisioning is unavailable in this converted game."
        } else if state == "startRejected" {
            detail = "The browser session could not start. Finish or cancel any existing sign-in and try again."
        } else if state == "presentationFailed" {
            detail = "The system could not present sign-in in the game window."
        } else {
            detail = "The login provider returned an error. The game's original error callback was preserved."
        }
        var lines = [detail]
        if let domain { lines.append("\(domain) (\(code))") }
        context.notices.show(Notice(title, lines: lines, style: .warning, duration: .seconds(8), important: true))
    }

    private func writeReport() {
        guard let context else { return }
        ReportWriter.shared.write(report, to: context.paths.diagnosticsDirectory(for: context.bundleIdentifier)
            .appendingPathComponent("authentication.json"))
    }
}
