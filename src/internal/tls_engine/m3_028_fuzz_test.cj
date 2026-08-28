package wirestack.internal.tls_engine

import std.env.getVariable
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.common.*
import wirestack.internal.transport.*
import wirestack.internal.trust.*

private const M3028_MUTATIONS: Int64 = 512

/** Bounded deterministic release qualification for the native TLS parsers. */
@Test
class M3028TlsFuzzTest {
    @TestCase
    func recordMutationsHaveDeterministicTypedTerminals(): Unit {
        let hello = m7023TlsSeed("tls-record", m3028ClientHello())
        @Assert(!hello.isEmpty())
        for (index in 0..M3028_MUTATIONS) {
            let input = m3028Mutate(hello, "record", index)
            let first = m3028ClassifyServerInput(input)
            let second = m3028ClassifyServerInput(input)
            @Assert(first, second)
        }
        println(
            "M7023_FUZZ target=tls-record seed=7023 " +
            "iterations=${M3028_MUTATIONS} decision=PASS"
        )
    }

    @TestCase
    func handshakeMutationsHaveDeterministicTypedTerminals(): Unit {
        let hello = m7023TlsSeed("tls-handshake", m3028ClientHello())
        @Assert(!hello.isEmpty())
        for (index in 0..M3028_MUTATIONS) {
            let input = m3028Mutate(hello, "handshake", index)
            let first = m3028ClassifyServerInput(input)
            let second = m3028ClassifyServerInput(input)
            @Assert(first, second)
        }
        println(
            "M7023_FUZZ target=tls-handshake seed=7023 " +
            "iterations=${M3028_MUTATIONS} decision=PASS"
        )
        if (getVariable("WIRESTACK_M7_023_TARGET").isNone()) {
            println(
                "M3028_FUZZ target=tls-record,tls-handshake seed=3028 " +
                "mutations=${M3028_MUTATIONS * 2} decision=PASS"
            )
        }
    }

    @TestCase
    func certificateAdapterMutationsHaveDeterministicTypedTerminals(): Unit {
        let certificate = m7023TlsSeed("certificate-adapter", tlsTestCertificateDer())
        for (index in 0..M3028_MUTATIONS) {
            let input = m3028Mutate(certificate, "certificate", index)
            let first = m3028ClassifyCertificate(input)
            let second = m3028ClassifyCertificate(input)
            @Assert(first, second)
        }
        println(
            "M7023_FUZZ target=certificate-adapter seed=7023 " +
            "iterations=${M3028_MUTATIONS} decision=PASS"
        )
        if (getVariable("WIRESTACK_M7_023_TARGET").isNone()) {
            println(
                "M3028_FUZZ target=certificate-adapter seed=3028 " +
                "mutations=${M3028_MUTATIONS} decision=PASS"
            )
        }
    }
}

private func m7023TlsSeed(target: String, fallback: Array<Byte>): Array<Byte> {
    match (getVariable("WIRESTACK_M7_023_TARGET")) {
        case None => fallback
        case Some(actual) =>
            if (actual != target) {
                throw IllegalStateException("M7-023 target mismatch: ${actual}")
            }
            match (getVariable("WIRESTACK_M7_023_CORPUS_HEX")) {
                case Some(value) => m7023TlsHex(value)
                case None => throw IllegalStateException("missing M7-023 corpus")
            }
    }
}

private func m7023TlsHex(value: String): Array<Byte> {
    let input = value.toArray()
    var digits: Int64 = 0
    for (byte in input) { if (byte > 32u8) { digits++ } }
    if (digits == 0 || digits % 2 != 0) {
        throw IllegalArgumentException("invalid M7-023 hex corpus")
    }
    let output = Array<Byte>(digits / 2, repeat: 0u8)
    var high: ?Byte = None<Byte>
    var index: Int64 = 0
    for (byte in input) {
        if (byte <= 32u8) { continue }
        let nibble = m7023TlsNibble(byte)
        match (high) {
            case None => high = Some(nibble)
            case Some(value) =>
                output[index] = (value << 4) | nibble
                index++
                high = None<Byte>
        }
    }
    output
}

private func m7023TlsNibble(value: Byte): Byte {
    if (value >= b'0' && value <= b'9') { value - b'0' }
    else if (value >= b'a' && value <= b'f') { value - b'a' + 10u8 }
    else if (value >= b'A' && value <= b'F') { value - b'A' + 10u8 }
    else { throw IllegalArgumentException("invalid M7-023 hex digit") }
}

private func m3028ClientHello(): Array<Byte> {
    let provider = AwsLcTlsProvider()
    let engine = provider.createEngine(
        TlsEngineRole.Client,
        TlsSecurityPolicy.forProfile(TlsSecurityProfile.Modern)
    )
    try {
        let _ = engine.handshakeStep()
        let output = Array<Byte>(64 * 1024, repeat: 0)
        let count = engine.drainCiphertext(MutableByteSpan(output))
        @Assert(count > 0)
        Array<Byte>(count, {index => output[index]})
    } finally {
        engine.close()
        provider.close()
    }
}

private func m3028Mutate(source: Array<Byte>, target: String, ordinal: Int64): Array<Byte> {
    let truncateEvery = ordinal % 11 == 0
    let length = if (truncateEvery) {
        ordinal % min(source.size, 96)
    } else {
        source.size
    }
    let output = Array<Byte>(length, {index => source[index]})
    if (output.isEmpty()) { return output }
    let start = if (target == "record") { 0 } else if (target == "handshake") { 5 } else { 0 }
    let span = max(1, output.size - min(start, output.size))
    let position = min(start, output.size - 1) + ((ordinal * 37 + 17) % span)
    let mask = UInt8(UInt64(1 << (ordinal % 8)))
    output[position] = output[position] ^ mask
    if (ordinal % 7 == 0 && output.size >= 5) {
        output[3] = UInt8(UInt64((ordinal * 13) & 0xff))
        output[4] = UInt8(UInt64((ordinal * 29) & 0xff))
    }
    output
}

private func m3028ClassifyServerInput(input: Array<Byte>): String {
    let provider = AwsLcTlsProvider()
    let identity = tlsTestLocalIdentity()
    let context = TlsServerContext.builder(
        provider.manifest(), provider.linuxCapabilities()
    ).identity(identity).build()
    let engine = provider.createServerEngine(context)
    try {
        let accepted = engine.feedCiphertext(ByteSpan(input))
        if (accepted != input.size) { return "bounded-input" }
        match (engine.handshakeStep()) {
            case TlsEngineStep.Complete => "complete"
            case TlsEngineStep.WantRead => "want-read"
            case TlsEngineStep.WantWrite => "want-write"
            case TlsEngineStep.NeedSignature => "need-signature"
            case TlsEngineStep.NeedServerSelection => "need-server-selection"
        }
    } catch (_: TlsEngineException) {
        "typed-tls-error"
    } finally {
        engine.close()
        identity.privateKeyRef.close()
        provider.close()
    }
}

private func m3028ClassifyCertificate(input: Array<Byte>): String {
    var provider: ?AwsLcTlsProvider = None<AwsLcTlsProvider>
    try {
        let certificate = DerCertificate(input)
        let created = AwsLcTlsProvider()
        provider = Some(created)
        let context = TlsClientContext.builder(
            created.manifest(), created.linuxCapabilities()
        ).trust(TrustPolicy.customRoots(CertificateChain([certificate]))).build()
        let engine = created.createClientEngine(
            context,
            ReferenceIdentity.Dns(HostName("example.com")),
            serverName: Some(HostName("example.com"))
        )
        engine.close()
        "accepted"
    } catch (_: CertificateInputException) {
        "typed-certificate-input-error"
    } catch (_: IllegalArgumentException) {
        "typed-input-error"
    } catch (_: TlsEngineException) {
        "typed-tls-error"
    } catch (_: TlsProviderException) {
        "typed-provider-error"
    } finally {
        match (provider) { case Some(value) => value.close(); case None => () }
    }
}
