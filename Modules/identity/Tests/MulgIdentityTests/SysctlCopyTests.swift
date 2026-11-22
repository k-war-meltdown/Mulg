import Foundation
import Testing
import MulgIdentityHooks

/// The sysctl(3) contract the identity hooks must follow (PLAN.md §3.4).
@Suite("mulg_sysctl_copy_string")
struct SysctlCopyTests {
    @Test("A NULL buffer reports the required length, including the NUL")
    func sizeQuery() {
        var length = 0
        let result = mulg_sysctl_copy_string("iPad17,3", nil, &length)
        #expect(result == 0)
        #expect(length == 9)
    }

    @Test("An exactly-sized buffer succeeds (upstream bug b rejected it)")
    func exactSize() {
        var length = 0
        _ = mulg_sysctl_copy_string("J820AP", nil, &length)
        var buffer = [CChar](repeating: 0x7F, count: length)
        let result = buffer.withUnsafeMutableBytes { raw in
            mulg_sysctl_copy_string("J820AP", raw.baseAddress, &length)
        }
        #expect(result == 0)
        #expect(length == 7)
        #expect(String(cString: buffer) == "J820AP")
    }

    @Test("A too-small buffer fails with -1 and errno ENOMEM (upstream bug c returned ENOMEM)")
    func tooSmall() {
        var length = 4
        var buffer = [CChar](repeating: 0x7F, count: 16)
        errno = 0
        let result = buffer.withUnsafeMutableBytes { raw in
            mulg_sysctl_copy_string("iPad17,3", raw.baseAddress, &length)
        }
        #expect(result == -1)
        #expect(errno == ENOMEM)
        #expect(length == 0)
        #expect(buffer.allSatisfy { $0 == 0x7F })
    }

    @Test("A short-buffer failure can be followed by a size query and a complete retry")
    func retryAfterShortBuffer() {
        var length = 1
        var short: CChar = 0x7F
        #expect(mulg_sysctl_copy_string("J820AP", &short, &length) == -1)
        #expect(length == 0)
        #expect(short == 0x7F)
        #expect(mulg_sysctl_copy_string("J820AP", nil, &length) == 0)
        #expect(length == 7)
        var buffer = [CChar](repeating: 0x7F, count: length)
        let result = buffer.withUnsafeMutableBytes { raw in
            mulg_sysctl_copy_string("J820AP", raw.baseAddress, &length)
        }
        #expect(result == 0)
        #expect(length == 7)
        #expect(String(cString: buffer) == "J820AP")
    }

    @Test("A non-null zero-capacity buffer is left untouched")
    func zeroCapacity() {
        var length = 0
        var byte: CChar = 0x7F
        errno = 0
        #expect(mulg_sysctl_copy_string("J820AP", &byte, &length) == -1)
        #expect(errno == ENOMEM)
        #expect(length == 0)
        #expect(byte == 0x7F)
    }

    @Test("The copied length is written back (upstream bug e)")
    func lengthWrittenBack() {
        var length = 64
        var buffer = [CChar](repeating: 0, count: 64)
        let result = buffer.withUnsafeMutableBytes { raw in
            mulg_sysctl_copy_string("iPad17,3", raw.baseAddress, &length)
        }
        #expect(result == 0)
        #expect(length == 9)
    }

    @Test("A buffer without a length is rejected with EINVAL")
    func missingLength() {
        var buffer = [CChar](repeating: 0, count: 16)
        errno = 0
        let result = buffer.withUnsafeMutableBytes { raw in
            mulg_sysctl_copy_string("iPad17,3", raw.baseAddress, nil)
        }
        #expect(result == -1)
        #expect(errno == EINVAL)
    }
}
