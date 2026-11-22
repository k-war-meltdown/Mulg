import Testing
@testable import MulgLibrary

@Suite("Compatibility preserves native bundle access")
struct SandboxCompatibilityRulesTests {
    @Test func removesLegacyBareFileDenialsIncludingOlderUserProfiles() {
        let rules = ["(deny file* file-read* file-read-metadata file-ioctl)",
                     "  (deny\nfile-read*\tfile-map-executable)  "]
        #expect(SandboxCompatibilityRules.preservingNativeFileAccess(rules).isEmpty)
    }

    @Test func preservesPathFiltersNativeAllowsAndNonFileRules() {
        let rules = ["(deny file* (literal \"/bin/sh\"))",
                     "(deny file-read* (subpath \"/private/var/lib/apt\"))",
                     "(deny process-fork)",
                     "(deny file* process-fork)",
                     "(allow file-read* file-map-executable (subpath \"/Volumes/Games/My Game.app\"))"]
        #expect(SandboxCompatibilityRules.preservingNativeFileAccess(rules) == rules)
    }
}
