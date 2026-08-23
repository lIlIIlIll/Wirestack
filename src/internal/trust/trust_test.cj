package wirestack.internal.trust

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.common.*

@Test
class TrustPolicyTest {
    @TestCase
    func nativeX509ParserAcceptsOneExactDerObjectAndRejectsTrailingBytes(): Unit {
        let der = certificateFixture()
        let certificate = DerCertificate(der)
        @Expect(certificate.derBytes().size, der.size)
        @Expect(certificate.extensionCount, 4)
        let names = certificate.subjectAlternativeNames()
        @Expect(names.dnsSubjectAlternativeNames().size, 2)
        @Expect(names.ipSubjectAlternativeNames().size, 1)
        let wildcard = HostnameVerifier.verify(
            names,
            ReferenceIdentity.Dns(HostName("api.example.org"))
        )
        @Expect(wildcard.wildcard)
        let ip = HostnameVerifier.verify(
            names,
            ReferenceIdentity.Ip(IpAddress(IpAddressFamily.Ipv4, [127, 0, 0, 1]))
        )
        @Expect(ip.matchedSubjectAlternativeName.startsWith("ipv4:"))

        let trailing = ArrayList<Byte>()
        trailing.add(all: der)
        trailing.add(0)
        let withTrailingByte = trailing.toArray()
        var rejected = false
        try {
            let _ = DerCertificate(withTrailingByte)
        } catch (error: CertificateInputException) {
            rejected = isCertificateError(error.code, CertificateInputErrorCode.InvalidDer)
        }
        @Expect(rejected)
    }

    @TestCase
    func certificateAndChainLimitsFailBeforeUnboundedParsingOrCopying(): Unit {
        let der = certificateFixture()
        var certificateLimit = false
        try {
            let _ = DerCertificate(
                der,
                limits: CertificateInputLimits(
                    maximumCertificateBytes: 800,
                    maximumChainBytes: 800
                )
            )
        } catch (error: CertificateInputException) {
            certificateLimit = isCertificateError(
                error.code,
                CertificateInputErrorCode.CertificateTooLarge
            )
        }
        @Expect(certificateLimit)

        let certificate = DerCertificate(der)
        var chainLength = false
        try {
            let _ = CertificateChain(
                [certificate, certificate],
                limits: CertificateInputLimits(
                    maximumChainLength: 1,
                    maximumCertificateBytes: 900,
                    maximumChainBytes: 2000
                )
            )
        } catch (error: CertificateInputException) {
            chainLength = isCertificateError(error.code, CertificateInputErrorCode.ChainTooLong)
        }
        @Expect(chainLength)

        var duplicate = false
        try {
            let _ = CertificateChain([certificate, certificate])
        } catch (error: CertificateInputException) {
            duplicate = isCertificateError(
                error.code,
                CertificateInputErrorCode.DuplicateCertificate
            )
        }
        @Expect(duplicate)

        var aggregateBytes = false
        try {
            let _ = CertificateChain(
                [certificate, certificate],
                limits: CertificateInputLimits(
                    maximumCertificateBytes: 900,
                    maximumChainBytes: 1000
                )
            )
        } catch (error: CertificateInputException) {
            aggregateBytes = isCertificateError(error.code, CertificateInputErrorCode.ChainTooLarge)
        }
        @Expect(aggregateBytes)
    }

    @TestCase
    func everyTrustPolicyHasAStableContentIdentityAndNoTrustAllState(): Unit {
        let chain = CertificateChain([DerCertificate(certificateFixture())])
        let first = TrustPolicy.customRoots(chain)
        let second = TrustPolicy.customRoots(chain)
        let combined = TrustPolicy.systemPlusCustomRoots(chain)
        let system = TrustPolicy.system()
        @Expect(first.contextIdentity.size, 64)
        @Expect(first.contextIdentity, second.contextIdentity)
        @Expect(first.contextIdentity != combined.contextIdentity)
        @Expect(first.contextIdentity != system.contextIdentity)

        let pin = SpkiSha256Pin(Array<Byte>(32, repeat: 9))
        let pinned = TrustPolicy.pinnedPublicKeys([pin])
        @Expect(pinned.pins().size, 1)
        @Expect(pinned.contextIdentity != system.contextIdentity)
    }

    @TestCase
    func pinAlgorithmAndScopeAreExplicitAndMalformedPinsFail(): Unit {
        var rejected = false
        try {
            let _ = SpkiSha256Pin(Array<Byte>(31, repeat: 0))
        } catch (_: IllegalArgumentException) {
            rejected = true
        }
        @Expect(rejected)

        let pin = SpkiSha256Pin(
            Array<Byte>(32, repeat: 1),
            scope: PinScope.AnyCertificateSubjectPublicKeyInfo
        )
        @Expect(isAnyCertificateScope(pin.scope))
    }
}

private func trustTestCertificateDer(): Array<Byte> {
    decodeBase64(
        "MIIDQzCCAiugAwIBAgIUV5PGYfjXOQnu+igzQly36jWWRgowDQYJKoZIhvcNAQELBQAwGjEYMBYGA1UEAwwPaWdub3JlZC5leGFtcGxlMB4XDTI2MDgyMzE5NTMyNVoXDTI2MDgyNDE5NTMyNVowGjEYMBYGA1UEAwwPaWdub3JlZC5leGFtcGxlMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAuQugF5gdGjMYdi0nY2Agd85kifIDv0NjOO+Wf1Att0pAQKp9I+7JJZzRElhj/2sCGMM+uS+mhcVV88jIDDSa5o9w0LeX5Rgl73Wm6m4fZWdywOzlZQ9Mo7CgmluShrv+Kps7gw94iApgvgzWtfBlXQJsRZil3Agtl2s8h+7v7CBf0iZ2EYGR3GFQJHTUFYJiCpOuiCT9FDG3rjwn1XA+r9Xg1LK2uAZ8wdv6VSrcuoiPE5SH33KDpg4XXgbNP6+PItb3+pRCk/5jWXG3CLHuc4kCwy9R4nG7XVKIC89Ye1bf08ZWcIWgEfwb7Mz3tvisJZ4pekbrMtx0MmHvuhY6hQIDAQABo4GAMH4wHQYDVR0OBBYEFDh1w+O/EI8PmXPwMAgNhbGaA63sMB8GA1UdIwQYMBaAFDh1w+O/EI8PmXPwMAgNhbGaA63sMA8GA1UdEwEB/wQFMAMBAf8wKwYDVR0RBCQwIoILZXhhbXBsZS5jb22CDSouZXhhbXBsZS5vcmeHBH8AAAEwDQYJKoZIhvcNAQELBQADggEBADzEAhmpVV1+ZPPmUXplLVBthDbVTmFlIwPMoUlzk7gQjNjKpjIRTPpRXQddr//UtCia9am74pJNr265vbVMAVWUCoIirkOtEvWc5FLjo1ZOCHo6Di8rMg1ThA1sRMjAKkMn5iw8f8vldJ2AXWpjxGK8yCZj063M9XShzzV95+BCGkmIJTXtG8mKcRko4sFQ1jWHBW4jX0PcLksB+1U8MBpevxgqoa8lgZQFzQhuFmGlJmXThCUWWElsKkwJSU62/E6wm1oxE+tngPQ4itqH0HS0X5YuEjCch8LgYetttH8eXSRkjNN+hY3e0a1jfhFDSqjH1i90c99oyJg1l5BXk0A="
    )
}

private func certificateFixture(): Array<Byte> { trustTestCertificateDer() }

private func decodeBase64(value: String): Array<Byte> {
    let output = ArrayList<Byte>()
    var accumulator: Int64 = 0
    var bits: Int64 = 0
    for (byte in value.toArray()) {
        if (byte == b'=') { break }
        let decoded: Int64 = if (byte >= b'A' && byte <= b'Z') {
            Int64(byte - b'A')
        } else if (byte >= b'a' && byte <= b'z') {
            Int64(byte - b'a') + 26
        } else if (byte >= b'0' && byte <= b'9') {
            Int64(byte - b'0') + 52
        } else if (byte == b'+') {
            62
        } else if (byte == b'/') {
            63
        } else {
            throw IllegalArgumentException("invalid base64 test fixture")
        }
        accumulator = (accumulator << 6) | decoded
        bits += 6
        if (bits >= 8) {
            bits -= 8
            output.add(UInt8(UInt64((accumulator >> bits) & 0xff)))
            accumulator &= if (bits == 0) { 0 } else { (1 << bits) - 1 }
        }
    }
    output.toArray()
}

private func isCertificateError(
    actual: CertificateInputErrorCode,
    expected: CertificateInputErrorCode
): Bool {
    match ((actual, expected)) {
        case (CertificateInputErrorCode.EmptyChain, CertificateInputErrorCode.EmptyChain) => true
        case (CertificateInputErrorCode.ChainTooLong, CertificateInputErrorCode.ChainTooLong) => true
        case (CertificateInputErrorCode.CertificateTooLarge, CertificateInputErrorCode.CertificateTooLarge) => true
        case (CertificateInputErrorCode.ChainTooLarge, CertificateInputErrorCode.ChainTooLarge) => true
        case (CertificateInputErrorCode.TooManyExtensions, CertificateInputErrorCode.TooManyExtensions) => true
        case (CertificateInputErrorCode.DuplicateCertificate, CertificateInputErrorCode.DuplicateCertificate) => true
        case (CertificateInputErrorCode.InvalidDer, CertificateInputErrorCode.InvalidDer) => true
        case (CertificateInputErrorCode.InvalidLimit, CertificateInputErrorCode.InvalidLimit) => true
        case _ => false
    }
}

private func isAnyCertificateScope(value: PinScope): Bool {
    match (value) {
        case PinScope.AnyCertificateSubjectPublicKeyInfo => true
        case _ => false
    }
}
