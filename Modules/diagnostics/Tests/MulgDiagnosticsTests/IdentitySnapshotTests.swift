import Foundation
@testable import MulgDiagnostics
import Testing

@Suite("Identity snapshot")
struct IdentitySnapshotTests {
    @Test("Reads strings, numbers and uname the way a game does")
    @MainActor
    func readsSignals() throws {
        #expect(IdentitySnapshot.sysctlString("kern.ostype") == "Darwin")
        #expect(IdentitySnapshot.sysctlString("no.such.name") == nil)
        #expect(IdentitySnapshot.sysctlNumber("hw.memsize") == ProcessInfo.processInfo.physicalMemory)
        #expect(IdentitySnapshot.cString((UInt8(0x69), UInt8(0x50), UInt8(0), UInt8(0x78))) == "iP")

        let values = IdentitySnapshot.collect()
        #expect(values["uname.machine"] == IdentitySnapshot.sysctlString("hw.machine"))
        #expect(values["ProcessInfo.activeProcessorCount"] == String(ProcessInfo.processInfo.activeProcessorCount))
        let json = try JSONSerialization.jsonObject(with: Data(IdentitySnapshot.json().utf8)) as? [String: String]
        #expect(json?["sysctl.hw.machine"] == values["sysctl.hw.machine"])
    }
}
