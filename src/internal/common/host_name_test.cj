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
        let invalid: Array<String> = ["", ".", ".example", "example..com", "-example.com", "example-.com", "exa_mple.com", "例子.test"]
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
}
