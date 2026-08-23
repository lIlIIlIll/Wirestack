package wirestack.internal.tls_engine

import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.trust.*

@Test
class LocalIdentityTest {
    @TestCase
    func pkcs8InputIsExactBoundedAndZeroizable(): Unit {
        let encoded = tlsTestPrivateKeyDer()
        let key = PrivateKeyRef.pkcs8(encoded)
        @Expect(!key.isClosed())
        key.close()
        @Expect(key.isClosed())

        let trailing = Array<Byte>(encoded.size + 1, {index =>
            if (index < encoded.size) { encoded[index] } else { 0 }
        })
        var rejected = false
        try {
            let _ = PrivateKeyRef.pkcs8(trailing)
        } catch (error: PrivateKeyException) {
            match (error.code) {
                case PrivateKeyErrorCode.InvalidPkcs8 => rejected = true
                case _ => ()
            }
        }
        @Expect(rejected)
    }

    @TestCase
    func pkcs8FileAdapterReadsOneBoundedRegularFile(): Unit {
        let temporary = File.createTemp("/tmp")
        let path = temporary.info.path.toString()
        temporary.close()
        try {
            File.writeTo(path, tlsTestPrivateKeyDer())
            let key = PrivateKeyRef.pkcs8File(path)
            @Expect(!key.isClosed())
            key.close()
        } finally {
            remove(path)
        }
    }

    @TestCase
    func localIdentityValidatesLeafKeyMatchAndHasStablePublicIdentity(): Unit {
        let first = tlsTestLocalIdentity()
        let second = tlsTestLocalIdentity()
        try {
            @Expect(first.contextIdentity, second.contextIdentity)
            @Expect(first.contextIdentity.size, 64)
        } finally {
            first.privateKeyRef.close()
            second.privateKeyRef.close()
        }
    }

    @TestCase
    func mismatchedCertificateAndPrivateKeyFailAtIdentityBuild(): Unit {
        let mismatched = DerCertificate(decodeTlsTestBase64(
            "MIIDQzCCAiugAwIBAgIUV5PGYfjXOQnu+igzQly36jWWRgowDQYJKoZIhvcNAQELBQAwGjEYMBYGA1UEAwwPaWdub3JlZC5leGFtcGxlMB4XDTI2MDgyMzE5NTMyNVoXDTI2MDgyNDE5NTMyNVowGjEYMBYGA1UEAwwPaWdub3JlZC5leGFtcGxlMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAuQugF5gdGjMYdi0nY2Agd85kifIDv0NjOO+Wf1Att0pAQKp9I+7JJZzRElhj/2sCGMM+uS+mhcVV88jIDDSa5o9w0LeX5Rgl73Wm6m4fZWdywOzlZQ9Mo7CgmluShrv+Kps7gw94iApgvgzWtfBlXQJsRZil3Agtl2s8h+7v7CBf0iZ2EYGR3GFQJHTUFYJiCpOuiCT9FDG3rjwn1XA+r9Xg1LK2uAZ8wdv6VSrcuoiPE5SH33KDpg4XXgbNP6+PItb3+pRCk/5jWXG3CLHuc4kCwy9R4nG7XVKIC89Ye1bf08ZWcIWgEfwb7Mz3tvisJZ4pekbrMtx0MmHvuhY6hQIDAQABo4GAMH4wHQYDVR0OBBYEFDh1w+O/EI8PmXPwMAgNhbGaA63sMB8GA1UdIwQYMBaAFDh1w+O/EI8PmXPwMAgNhbGaA63sMA8GA1UdEwEB/wQFMAMBAf8wKwYDVR0RBCQwIoILZXhhbXBsZS5jb22CDSouZXhhbXBsZS5vcmeHBH8AAAEwDQYJKoZIhvcNAQELBQADggEBADzEAhmpVV1+ZPPmUXplLVBthDbVTmFlIwPMoUlzk7gQjNjKpjIRTPpRXQddr//UtCia9am74pJNr265vbVMAVWUCoIirkOtEvWc5FLjo1ZOCHo6Di8rMg1ThA1sRMjAKkMn5iw8f8vldJ2AXWpjxGK8yCZj063M9XShzzV95+BCGkmIJTXtG8mKcRko4sFQ1jWHBW4jX0PcLksB+1U8MBpevxgqoa8lgZQFzQhuFmGlJmXThCUWWElsKkwJSU62/E6wm1oxE+tngPQ4itqH0HS0X5YuEjCch8LgYetttH8eXSRkjNN+hY3e0a1jfhFDSqjH1i90c99oyJg1l5BXk0A="
        ))
        let key = PrivateKeyRef.pkcs8(tlsTestPrivateKeyDer())
        var rejected = false
        try {
            let _ = LocalIdentity(CertificateChain([mismatched]), key)
        } catch (error: PrivateKeyException) {
            match (error.code) {
                case PrivateKeyErrorCode.KeyCertificateMismatch => rejected = true
                case _ => ()
            }
        } finally {
            key.close()
        }
        @Expect(rejected)
    }
}
