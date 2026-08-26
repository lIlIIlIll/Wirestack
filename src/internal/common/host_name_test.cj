package wirestack.internal.common

import std.unittest.*
import std.unittest.testmacro.*

@Test
class HostNameTest {
    @TestCase
    func canonicalizesAsciiCaseAndOneRootDot(): Unit {
        @Expect(HostName("WWW.Example.COM.").ascii, "www.example.com")
        @Expect(HostName("www.example.com"), HostName("WWW.EXAMPLE.COM"))
    }

    @TestCase
    func rejectsAmbiguousOrInvalidDnsNames(): Unit {
        let invalid: Array<String> = [
            "", ".", "example.com..", ".example", "example..com",
            "-example.com", "example-.com", "exa_mple.com", "例子.test",
            "example.com:443", "user@example.com", "[2001:db8::1]",
            "example.com/path", "example.com?query", "example.com#fragment"
        ]
        for (value in invalid) {
            var rejected = false
            try {
                let _ = HostName(value)
            } catch (_: IllegalArgumentException) {
                rejected = true
            }
            @Expect(rejected)
        }
    }

    @TestCase
    func acceptsAsciiALabelAndExactDnsLengthBoundaries(): Unit {
        @Expect(HostName("XN--BCHER-KVA.Example.").ascii, "xn--bcher-kva.example")

        let label63 = asciiLabel(63)
        let label61 = asciiLabel(61)
        let maximum = "${label63}.${label63}.${label63}.${label61}"
        @Assert(maximum.size, 253)
        @Expect(HostName("${maximum}.").ascii, maximum)
    }

    @TestCase
    func rejectsOneByteBeyondLabelAndHostLimits(): Unit {
        let label63 = asciiLabel(63)
        let label62 = asciiLabel(62)
        let label64 = asciiLabel(64)
        let host254 = "${label63}.${label63}.${label63}.${label62}"
        @Assert(host254.size, 254)

        for (value in ["${label64}.example", host254]) {
            var rejected = false
            try {
                let _ = HostName(value)
            } catch (_: IllegalArgumentException) {
                rejected = true
            }
            @Expect(rejected)
        }
    }
}

private func asciiLabel(size: Int64): String {
    String.fromUtf8(Array<Byte>(size, repeat: b'a'))
}
