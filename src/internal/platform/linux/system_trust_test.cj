package wirestack.internal.platform.linux

import std.unittest.*
import std.unittest.testmacro.*

@Test
class LinuxSystemTrustAdapterTest {
    @TestCase
    func frozenSearchOrderCoversGlibcAndMuslLayouts(): Unit {
        let bundles = LinuxSystemTrustAdapter.bundleCandidates()
        @Expect(bundles[0], "/etc/ssl/certs/ca-certificates.crt")
        @Expect(bundles.contains("/etc/pki/tls/certs/ca-bundle.crt"))
        @Expect(bundles.contains("/etc/ssl/ca-bundle.pem"))
        let directories = LinuxSystemTrustAdapter.directoryCandidates()
        @Expect(directories[0], "/etc/ssl/certs")
        @Expect(directories.contains("/etc/pki/tls/certs"))
    }

    @TestCase
    func currentLinuxHostSelectsOneExplicitUsableSource(): Unit {
        let location = LinuxSystemTrustAdapter.discover()
        @Expect(location.sourceIdentity.startsWith("linux-ca-"))
        @Expect(location.certificateBundle.isSome() !=
            location.hashedCertificateDirectory.isSome())
    }

    @TestCase
    func missingCandidatesFailWithoutProviderDefaultFallback(): Unit {
        var failed = false
        try {
            let _ = LinuxSystemTrustAdapter.discoverFrom(
                ["/wirestack/does-not-exist/ca.pem"],
                ["/wirestack/does-not-exist/certs"]
            )
        } catch (error: LinuxSystemTrustException) {
            match (error.code) {
                case LinuxSystemTrustErrorCode.NoUsableTrustSource => failed = true
                case _ => ()
            }
        }
        @Expect(failed)
    }
}
