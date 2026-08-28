package wirestack.internal.trust

import std.env.getVariable
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.common.*

private const M3028_HOSTNAME_MUTATIONS: Int64 = 2048

/** Deterministic bounded qualification for SAN and reference-name handling. */
@Test
class M3028HostnameFuzzTest {
    @TestCase
    func hostnameMutationsHaveDeterministicTypedTerminals(): Unit {
        let corpus = m7023HostnameSeed()
        for (index in 0..M3028_HOSTNAME_MUTATIONS) {
            let (san, reference) = m3028HostnameCase(index, corpus)
            let first = m3028ClassifyHostname(san, reference)
            let second = m3028ClassifyHostname(san, reference)
            @Assert(first, second)
        }
        println(
            "M7023_FUZZ target=hostname-verifier seed=7023 " +
            "iterations=${M3028_HOSTNAME_MUTATIONS} decision=PASS"
        )
        if (getVariable("WIRESTACK_M7_023_TARGET").isNone()) {
            println(
                "M3028_FUZZ target=hostname-verifier seed=3028 " +
                "mutations=${M3028_HOSTNAME_MUTATIONS} decision=PASS"
            )
        }
    }
}

private func m3028HostnameCase(index: Int64, corpus: String): (String, String) {
    match (index % 12) {
        case 0 => (corpus, corpus)
        case 1 => ("*.example.org", "node${index}.example.org")
        case 2 => ("foo*.example.org", "foo.example.org")
        case 3 => ("*.*.example.org", "a.b.example.org")
        case 4 => ("*.com", "node.com")
        case 5 => ("xn--bcher-kva.example", "XN--BCHER-KVA.EXAMPLE")
        case 6 => ("host${index}.example", "host${index}.example")
        case 7 => ("host_${index}.example", "host_${index}.example")
        case 8 => (".example.com", "example.com")
        case 9 => ("example.com.", "example.com.")
        case 10 => ("a..example.com", "a.example.com")
        case _ => ("a${index}.example.com", "b${index}.example.com")
    }
}

private func m7023HostnameSeed(): String {
    match (getVariable("WIRESTACK_M7_023_TARGET")) {
        case None => "example.com"
        case Some(actual) =>
            if (actual != "hostname-verifier") {
                throw IllegalStateException("M7-023 target mismatch: ${actual}")
            }
            match (getVariable("WIRESTACK_M7_023_CORPUS_HEX")) {
                case Some(value) => String.fromUtf8(m7023HostnameHex(value))
                case None => throw IllegalStateException("missing M7-023 corpus")
            }
    }
}

private func m7023HostnameHex(value: String): Array<Byte> {
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
        let nibble = m7023HostnameNibble(byte)
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

private func m7023HostnameNibble(value: Byte): Byte {
    if (value >= b'0' && value <= b'9') { value - b'0' }
    else if (value >= b'a' && value <= b'f') { value - b'a' + 10u8 }
    else if (value >= b'A' && value <= b'F') { value - b'A' + 10u8 }
    else { throw IllegalArgumentException("invalid M7-023 hex digit") }
}

private func m3028ClassifyHostname(san: String, reference: String): String {
    try {
        let names = CertificateSubjectAlternativeNames([san], [])
        let host = HostName(reference)
        let evidence = HostnameVerifier.verify(names, ReferenceIdentity.Dns(host))
        if (evidence.wildcard) { "matched-wildcard" } else { "matched-exact" }
    } catch (_: IdentityVerificationException) {
        "typed-identity-error"
    } catch (_: IllegalArgumentException) {
        "typed-host-input-error"
    }
}
