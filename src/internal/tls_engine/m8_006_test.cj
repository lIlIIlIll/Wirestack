package wirestack.internal.tls_engine

import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api
import wirestack.internal.trust.*

@Test
class TlsM8006ContextTest {
    @TestCase
    func sessionPartitionsRetainOnlyTheMatchingContextVersion(): Unit {
        let first = TlsSessionKey(
            "server", "h2", "trust", "client", "provider", "12-13",
            contextVersion: 41u64
        )
        let replacement = TlsSessionKey(
            "server", "h2", "trust", "client", "provider", "12-13",
            contextVersion: 42u64
        )
        @Expect(!first.sameAs(replacement))

        let store = TlsSessionStore()
        try {
            store.put(first, [7u8, 8u8], 60u64, false)
            @Expect(store.take(replacement).isNone())
            @Expect(store.take(first).getOrThrow(), [7u8, 8u8])
            @Expect(store.take(first).getOrThrow(), [7u8, 8u8])
        } finally {
            store.close()
        }
    }

    @TestCase
    func decryptorRequiresProviderCapabilityAndRsaExternalIdentity(): Unit {
        let decryptor = M8006InternalDecryptor()
        let fileIdentity = tlsTestLocalIdentity()
        try {
            let wrongIdentity = @AssertThrows[TlsContextException](
                TlsServerContext.builder(m8006Manifest(), m8006Capabilities())
                    .identity(fileIdentity)
                    .withExternalDecryptor(decryptor)
                    .build()
            )
            match (wrongIdentity.code) {
                case TlsContextErrorCode.InvalidHook => ()
                case _ => @Fail("file-backed decryptor did not fail with InvalidHook")
            }
        } finally {
            fileIdentity.privateKeyRef.close()
        }

        let externalKey = PrivateKeyRef.externalSigner(
            "m8-006-rsa",
            tlsTestSubjectPublicKeyInfoDer(),
            M8006RsaSigner()
        )
        let externalIdentity = LocalIdentity(
            CertificateChain([DerCertificate(tlsTestCertificateDer())]),
            externalKey
        )
        try {
            let withoutCapability = m8006Manifest(bits: 0x1ffu64)
            let error = @AssertThrows[TlsContextException](
                TlsServerContext.builder(
                    withoutCapability,
                    TlsCapabilities.fromProvider(withoutCapability)
                ).identity(externalIdentity)
                    .withExternalDecryptor(decryptor)
                    .build()
            )
            let rejected = match (error.capability) {
                case Some(value) => match (value) {
                    case TlsCapability.ExternalDecryptor => true
                    case _ => false
                }
                case None => false
            }
            @Expect(rejected)
        } finally {
            externalKey.close()
        }
    }

    @TestCase
    func keyLogSinkRequiresExplicitProviderCapability(): Unit {
        let withoutKeyLog = m8006Manifest(bits: 0x3ffu64)
        let error = @AssertThrows[TlsContextException](
            TlsClientContext.builder(
                withoutKeyLog,
                TlsCapabilities.fromProvider(withoutKeyLog)
            ).trust(m8006Trust())
                .withKeyLogSink(M8006KeyLogSink())
                .build()
        )
        let rejected = match (error.capability) {
            case Some(value) => match (value) {
                case TlsCapability.KeyLog => true
                case _ => false
            }
            case None => false
        }
        @Expect(rejected)
    }
}

private class M8006InternalDecryptor <: api.ExternalDecryptor {
    public func decrypt(
        request: api.ExternalDecryptionRequest,
        _: api.OperationContext
    ): Array<Byte> {
        request.ciphertextBytes()
    }
}

private class M8006KeyLogSink <: api.KeyLogSink {
    public func emit(_: api.TlsKeyLogLine, _: api.OperationContext): Unit {}
}

private class M8006RsaSigner <: ExternalSigner {
    public func supportedAlgorithms(): Array<TlsSignatureAlgorithm> {
        [TlsSignatureAlgorithm.RsaPssRsaeSha256]
    }

    public func sign(
        _: ExternalSignatureRequest,
        _: api.OperationContext
    ): Array<Byte> {
        [1u8]
    }
}

private func m8006Manifest(bits!: UInt64 = 0x7ffu64): TlsProviderManifest {
    TlsProviderManifest(
        "m8-006-provider",
        "1",
        "m8-006-fingerprint",
        "static",
        "test",
        bits
    )
}

private func m8006Capabilities(): TlsCapabilities {
    TlsCapabilities.fromProvider(m8006Manifest())
}

private func m8006Trust(): TrustPolicy {
    TrustPolicy.pinnedPublicKeys([SpkiSha256Pin(Array<Byte>(32, repeat: 7))])
}
