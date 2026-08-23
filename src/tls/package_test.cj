package wirestack.tls

import std.unittest.*

@Test
public class TlsRuntimeTest {
    @TestCase
    func reportsHandleFreeLinuxProviderAndBuildIdentity(): Unit {
        let info = TlsRuntime.info()
        @Expect(info.transportBackend, "std-net")
        @Expect(info.runtimeIoBackend, "cjnative")
        @Expect(info.tlsProvider, "aws-lc")
        @Expect(info.tlsProviderVersion, "5.5.0")
        @Expect(!info.trustBackend.isEmpty())
        @Expect(info.targetTriple.contains("linux"))
        @Expect(!info.externalOpenSslDependency)
        @Expect(!info.buildFingerprint.isEmpty())
        @Expect(info.supportedTlsVersions, ["1.2", "1.3"])
        @Expect(info.httpVersions, ["1.1", "2"])
        @Expect(info.featureFlags.contains("session-resumption"))
    }

    @TestCase
    func returnsDefensiveCopiesOfRuntimeInventories(): Unit {
        let info = TlsRuntime.info()
        let versions = info.supportedTlsVersions
        versions[0] = "mutated"
        @Expect(info.supportedTlsVersions, ["1.2", "1.3"])
    }
}
