package wirestack.internal.platform.linux

import std.fs.*
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

    @TestCase
    func directoryCandidateRequiresReadableHashedCertificateEntry(): Unit {
        let temporary = File.createTemp("/tmp")
        let directory = temporary.info.path.toString()
        temporary.close()
        remove(directory)
        Directory.create(directory)
        try {
            File.writeTo("${directory}/README", [1u8])
            @Expect(discoveryFailsForDirectory(directory))

            File.writeTo("${directory}/not-a-hash.0", [1u8])
            @Expect(discoveryFailsForDirectory(directory))

            File.writeTo("${directory}/0123abcd.0", [1u8])
            let location = LinuxSystemTrustAdapter.discoverFrom(
                ["/wirestack/does-not-exist/ca.pem"],
                [directory]
            )
            @Expect(location.certificateBundle.isNone())
            @Expect(location.hashedCertificateDirectory, Some(directory))
        } finally {
            remove(directory, recursive: true)
        }
    }

    @TestCase
    func sourceIdentityChangesWhenSameSizeTrustContentChanges(): Unit {
        let bundle = File.createTemp("/tmp")
        let bundlePath = bundle.info.path.toString()
        bundle.close()
        let directoryFile = File.createTemp("/tmp")
        let directory = directoryFile.info.path.toString()
        directoryFile.close()
        remove(directory)
        Directory.create(directory)
        try {
            File.writeTo(bundlePath, "abc".toArray())
            let firstBundle = LinuxSystemTrustAdapter.discoverFrom([bundlePath], [])
            File.writeTo(bundlePath, "xyz".toArray())
            let secondBundle = LinuxSystemTrustAdapter.discoverFrom([bundlePath], [])
            @Expect(firstBundle.sourceIdentity != secondBundle.sourceIdentity)

            let hashed = "${directory}/0123abcd.0"
            File.writeTo(hashed, "one".toArray())
            let firstDirectory = LinuxSystemTrustAdapter.discoverFrom([], [directory])
            File.writeTo(hashed, "two".toArray())
            let secondDirectory = LinuxSystemTrustAdapter.discoverFrom([], [directory])
            @Expect(firstDirectory.sourceIdentity != secondDirectory.sourceIdentity)
        } finally {
            remove(bundlePath)
            remove(directory, recursive: true)
        }
    }
}

private func discoveryFailsForDirectory(directory: String): Bool {
    try {
        let _ = LinuxSystemTrustAdapter.discoverFrom(
            ["/wirestack/does-not-exist/ca.pem"],
            [directory]
        )
        false
    } catch (error: LinuxSystemTrustException) {
        match (error.code) {
            case LinuxSystemTrustErrorCode.NoUsableTrustSource => true
            case _ => false
        }
    }
}
