package wirestack.internal.tls_engine

import std.unittest.*
import std.unittest.testmacro.*

@Test
class TlsContextSessionVersionTest {
    @TestCase
    func sessionKeysSeparateContextEpochs(): Unit {
        let first = TlsSessionKey("server", "h2", "trust", "client", "provider", "12-13", contextVersion: 1u64)
        let second = TlsSessionKey("server", "h2", "trust", "client", "provider", "12-13", contextVersion: 2u64)
        @Expect(!first.sameAs(second))
        @Expect(first.sameAs(TlsSessionKey("server", "h2", "trust", "client", "provider", "12-13", contextVersion: 1u64)))
    }
}
