package wirestack.internal.trust

import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.common.*

private const M3028_HOSTNAME_MUTATIONS: Int64 = 2048

/** Deterministic bounded qualification for SAN and reference-name handling. */
@Test
class M3028HostnameFuzzTest {
    @TestCase
    func hostnameMutationsHaveDeterministicTypedTerminals(): Unit {
        for (index in 0..M3028_HOSTNAME_MUTATIONS) {
            let (san, reference) = m3028HostnameCase(index)
            let first = m3028ClassifyHostname(san, reference)
            let second = m3028ClassifyHostname(san, reference)
            @Assert(first, second)
        }
        println(
            "M3028_FUZZ target=hostname-verifier seed=3028 " +
            "mutations=${M3028_HOSTNAME_MUTATIONS} decision=PASS"
        )
    }
}

private func m3028HostnameCase(index: Int64): (String, String) {
    match (index % 12) {
        case 0 => ("example.com", "EXAMPLE.COM")
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
