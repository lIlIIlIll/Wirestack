package wirestack.internal.tls_engine

import std.unittest.*
import std.unittest.testmacro.*

@Test
class AwsLcTlsProviderTest {
    @TestCase
    func exposesThePinnedProviderManifest(): Unit {
        let provider = AwsLcTlsProvider()
        try {
            let manifest = provider.manifest()
            @Expect(manifest.providerId, "aws-lc")
            @Expect(manifest.version, "5.5.0")
            @Expect(manifest.fingerprint,
                "0058686c2ce423c9c416c0597ae84bb30d07ee71271acf58e110f69f802f6478")
            @Expect(manifest.backend, "aws-lc-static")
            @Expect(manifest.patchLevel, "abi-1;patches=none")
            @Expect(manifest.supports(TlsProviderCapability.Tls12))
            @Expect(manifest.supports(TlsProviderCapability.Tls13))
            @Expect(manifest.supports(TlsProviderCapability.ExternalSigner))
            @Expect(manifest.supports(TlsProviderCapability.SessionResumption))
            @Expect(manifest.supports(TlsProviderCapability.SecureRandom))
        } finally {
            provider.close()
        }
    }

    @TestCase
    func fillsBuffersFromTheProviderCsprng(): Unit {
        let provider = AwsLcTlsProvider()
        try {
            let first = Array<Byte>(64, repeat: 0)
            let second = Array<Byte>(64, repeat: 0)
            provider.fillSecureRandom(first)
            provider.fillSecureRandom(second)
            @Expect(first != Array<Byte>(64, repeat: 0))
            @Expect(second != Array<Byte>(64, repeat: 0))
            @Expect(first != second)
            provider.fillSecureRandom(Array<Byte>())
        } finally {
            provider.close()
        }
    }

    @TestCase
    func closeIsIdempotentAndClosedUseFails(): Unit {
        let provider = AwsLcTlsProvider()
        provider.close()
        provider.close()
        var observed = false
        try {
            provider.fillSecureRandom(Array<Byte>(1, repeat: 0))
        } catch (error: TlsProviderException) {
            match (error.code) {
                case TlsProviderErrorCode.Closed => observed = true
                case _ => ()
            }
        }
        @Expect(observed)
    }

    @TestCase
    func repeatedProviderCleanupReleasesEveryInstance(): Unit {
        for (_ in 0..10_000) {
            let provider = AwsLcTlsProvider()
            provider.close()
        }
    }
}
