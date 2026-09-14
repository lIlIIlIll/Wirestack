package wirestack.tls

import std.unittest.*
import std.unittest.testmacro.*

@Test
class TlsM8006ContractTest {
    @TestCase
    func externalDecryptionRequestIsStrictlyRawRsaBoundedAndOwned(): Unit {
        let input = [1u8, 2u8, 3u8]
        let request = ExternalDecryptionRequest("RSA_RAW", input)
        input[0] = 9u8
        @Expect(request.algorithm, "RSA_RAW")
        @Expect(request.ciphertextBytes(), [1u8, 2u8, 3u8])

        @AssertThrows[TlsContextException](
            ExternalDecryptionRequest("RSA_PKCS1", [1u8])
        )
        @AssertThrows[TlsContextException](
            ExternalDecryptionRequest("RSA_RAW", Array<Byte>())
        )
        @AssertThrows[TlsContextException](
            ExternalDecryptionRequest("RSA_RAW", Array<Byte>(1025, repeat: 0))
        )
    }

    @TestCase
    func keyLogLineAcceptsOnlyBoundedNssShapeAndOwnsSecrets(): Unit {
        let random = Array<Byte>(32, repeat: 1)
        let secret = Array<Byte>(64, repeat: 2)
        let line = TlsKeyLogLine("CLIENT_TRAFFIC_SECRET_0", random, secret)
        random[0] = 8
        secret[0] = 9
        @Expect(line.clientRandomBytes()[0], 1)
        @Expect(line.secretBytes()[0], 2)

        @AssertThrows[TlsContextException](
            TlsKeyLogLine("client secret", Array<Byte>(32, repeat: 0), [1u8])
        )
        @AssertThrows[TlsContextException](
            TlsKeyLogLine(
                String.fromUtf8(Array<Byte>(129, repeat: b'A')),
                Array<Byte>(32, repeat: 0),
                [1u8]
            )
        )
        @AssertThrows[TlsContextException](
            TlsKeyLogLine("CLIENT_RANDOM", Array<Byte>(31, repeat: 0), [1u8])
        )
        @AssertThrows[TlsContextException](
            TlsKeyLogLine("CLIENT_RANDOM", Array<Byte>(32, repeat: 0), Array<Byte>(65, repeat: 0))
        )
    }

    @TestCase
    func clientContextRejectsExternalDecryptionBeforeHandshake(): Unit {
        let error = @AssertThrows[TlsContextException](
            TlsClientContext.builder()
                .withExternalDecryptor(M8006Decryptor())
                .build()
        )
        match (error.code) {
            case TlsContextErrorCode.InvalidHook => ()
            case _ => @Fail("client decryptor did not fail with InvalidHook")
        }
    }
}

private class M8006Decryptor <: ExternalDecryptor {
    public func decrypt(
        request: ExternalDecryptionRequest,
        _: OperationContext
    ): Array<Byte> {
        request.ciphertextBytes()
    }
}
