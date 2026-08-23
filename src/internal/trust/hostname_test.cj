package wirestack.internal.trust

import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.common.*

@Test
class HostnameVerifierTest {
    @TestCase
    func exactDnsAndAsciiIdnaALabelMatchCaseInsensitively(): Unit {
        let names = CertificateSubjectAlternativeNames(
            ["EXAMPLE.COM", "xn--bcher-kva.example"],
            []
        )
        let exact = HostnameVerifier.verify(names, ReferenceIdentity.Dns(HostName("example.com")))
        @Expect(exact.matchedSubjectAlternativeName, "example.com")
        @Expect(!exact.wildcard)

        let idna = HostnameVerifier.verify(
            names,
            ReferenceIdentity.Dns(HostName("XN--BCHER-KVA.EXAMPLE"))
        )
        @Expect(idna.referenceIdentity, "xn--bcher-kva.example")
    }

    @TestCase
    func wildcardMatchesExactlyOneLeftmostLabelOnly(): Unit {
        let names = CertificateSubjectAlternativeNames(["*.example.org"], [])
        let matched = HostnameVerifier.verify(
            names,
            ReferenceIdentity.Dns(HostName("api.example.org"))
        )
        @Expect(matched.wildcard)
        @Expect(dnsMismatch(names, "example.org"))
        @Expect(dnsMismatch(names, "deep.api.example.org"))
    }

    @TestCase
    func invalidOrOverbroadWildcardsAreRejectedAtCertificateBoundary(): Unit {
        for (value in ["foo*.example.org", "*.*.example.org", "*.com", "例子.example"]) {
            var rejected = false
            try {
                let _ = CertificateSubjectAlternativeNames([value], [])
            } catch (error: IdentityVerificationException) {
                rejected = isIdentityError(error.code, IdentityVerificationErrorCode.InvalidDnsSan)
            }
            @Expect(rejected)
        }
    }

    @TestCase
    func dnsAndIpReferenceIdentitiesNeverCrossMatch(): Unit {
        let loopback = IpAddress(IpAddressFamily.Ipv4, [127, 0, 0, 1])
        let dnsOnly = CertificateSubjectAlternativeNames(["127.0.0.1"], [])
        var ipRejected = false
        try {
            let _ = HostnameVerifier.verify(dnsOnly, ReferenceIdentity.Ip(loopback))
        } catch (error: IdentityVerificationException) {
            ipRejected = isIdentityError(error.code, IdentityVerificationErrorCode.NoMatchingIpSan)
        }
        @Expect(ipRejected)

        let ipOnly = CertificateSubjectAlternativeNames([], [loopback])
        @Expect(dnsMismatch(ipOnly, "127.0.0.1"))
        let matched = HostnameVerifier.verify(ipOnly, ReferenceIdentity.Ip(loopback))
        @Expect(matched.matchedSubjectAlternativeName.startsWith("ipv4:"))
    }

    @TestCase
    func subjectAlternativeNameCountIsHardBounded(): Unit {
        let names = Array<String>(257, {index => "host${index}.example"})
        var rejected = false
        try {
            let _ = CertificateSubjectAlternativeNames(names, [])
        } catch (error: IdentityVerificationException) {
            rejected = isIdentityError(
                error.code,
                IdentityVerificationErrorCode.TooManySubjectAlternativeNames
            )
        }
        @Expect(rejected)
    }
}

private func dnsMismatch(names: CertificateSubjectAlternativeNames, value: String): Bool {
    try {
        let _ = HostnameVerifier.verify(names, ReferenceIdentity.Dns(HostName(value)))
        false
    } catch (error: IdentityVerificationException) {
        isIdentityError(error.code, IdentityVerificationErrorCode.NoMatchingDnsSan)
    }
}

private func isIdentityError(
    actual: IdentityVerificationErrorCode,
    expected: IdentityVerificationErrorCode
): Bool {
    match ((actual, expected)) {
        case (IdentityVerificationErrorCode.NoMatchingDnsSan, IdentityVerificationErrorCode.NoMatchingDnsSan) => true
        case (IdentityVerificationErrorCode.NoMatchingIpSan, IdentityVerificationErrorCode.NoMatchingIpSan) => true
        case (IdentityVerificationErrorCode.InvalidDnsSan, IdentityVerificationErrorCode.InvalidDnsSan) => true
        case (IdentityVerificationErrorCode.TooManySubjectAlternativeNames, IdentityVerificationErrorCode.TooManySubjectAlternativeNames) => true
        case (IdentityVerificationErrorCode.ZonedIpReference, IdentityVerificationErrorCode.ZonedIpReference) => true
        case _ => false
    }
}
