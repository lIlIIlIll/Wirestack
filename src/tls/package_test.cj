package wirestack.tls

import std.unittest.*

@Test
public class TlsRuntimeTest {

    @TestCase
    func returnsDefensiveCopiesOfRuntimeInventories(): Unit {
        let info = TlsRuntime.info()
        let versions = info.supportedTlsVersions
        versions[0] = "mutated"
        @Expect(info.supportedTlsVersions, ["1.2", "1.3"])
    }
}
