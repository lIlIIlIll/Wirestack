package wirestack.internal.http1

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.common.*
import wirestack.internal.http_model.*
import wirestack.internal.tls_engine.*
import wirestack.internal.transport.*
import wirestack.internal.trust.*

@Test
class Http1TlsServerTest {
    @TestCase
    func alpnServerRejectsAClientWithNoSharedHttpProtocol(): Unit {
        let server = AwsLcHttp1ServerTlsHandshaker.createAlpn(
            [http1TlsTestCertificateDer()], http1TlsTestPrivateKeyDer()
        )
        let provider = AwsLcTlsProvider()
        let clientContext = TlsClientContext.builder(
            provider.manifest(), provider.linuxCapabilities()
        ).trust(TrustPolicy.pinnedPublicKeys([http1TlsServerPin()]))
            .alpn(["wirestack.invalid"])
            .build()
        let (clientTransport, serverTransport) = MemoryTransport.pair(capacity: 64 * 1024)
        let context = OperationContext(deadline: Some(Deadline.after(3 * Duration.second)))
        let accepting = spawn {
            try {
                let _ = server.handshakeNegotiated(serverTransport, context)
                false
            } catch (error: TlsEngineException) {
                match (error.tlsCode) {
                    case TlsEngineErrorCode.NoSharedAlpn => true
                    case _ => false
                }
            }
        }
        var clientRejected = false
        try {
            let engine = provider.createClientEngine(
                clientContext,
                ReferenceIdentity.Dns(HostName("example.com")),
                serverName: Some(HostName("example.com"))
            )
            let _ = TlsConnection.handshake(engine, clientTransport, context: context)
        } catch (_: Exception) {
            clientRejected = true
        } finally {
            @Expect(clientRejected)
            @Expect(accepting.get(3 * Duration.second))
            provider.close()
            server.close()
        }
    }

    @TestCase
    func automaticClientOffersH2FirstAndFallsBackToServerHttp11(): Unit {
        let server = AwsLcHttp1ServerTlsHandshaker.create(
            [http1TlsTestCertificateDer()], http1TlsTestPrivateKeyDer()
        )
        let client = AwsLcHttp1TlsHandshaker.createAlpn(
            TrustPolicy.pinnedPublicKeys([http1TlsServerPin()])
        )
        let (clientTransport, serverTransport) = MemoryTransport.pair(capacity: 64 * 1024)
        let context = OperationContext(deadline: Some(Deadline.after(3 * Duration.second)))
        try {
            let accepting = spawn { server.handshake(serverTransport, context) }
            let negotiated = client.handshakeNegotiated(
                HostName("example.com"), clientTransport, context
            )
            let accepted = accepting.get(3 * Duration.second)
            @Expect(client.alpnPolicy, "h2,http/1.1")
            @Expect(isTlsFallbackHttp11(negotiated.protocol))
            negotiated.transport.abort(reason: Some(AbortReason.ApplicationAbort))
            accepted.abort(reason: Some(AbortReason.ApplicationAbort))
        } finally {
            client.close()
            server.close()
        }
    }

    @TestCase
    func requiredMutualTlsCarriesAuthenticatedHttp1Exchange(): Unit {
        let certificate = http1TlsTestCertificateDer()
        let server = AwsLcHttp1ServerTlsHandshaker.create(
            [certificate], http1TlsTestPrivateKeyDer(),
            clientAuthentication: ClientAuthentication.Required,
            clientTrustRootsDer: [certificate]
        )
        let client = AwsLcHttp1TlsHandshaker.createWithDer(
            [certificate],
            clientCertificateChainDer: [certificate],
            clientPrivateKeyPkcs8Der: http1TlsTestPrivateKeyDer()
        )
        try {
            runTlsHttp1Exchange(server, client)
        } finally {
            client.close()
            server.close()
        }
    }

    @TestCase
    func realAwsLcHandshakeCarriesOneHttp1Exchange(): Unit {
        let server = AwsLcHttp1ServerTlsHandshaker.create(
            [http1TlsTestCertificateDer()], http1TlsTestPrivateKeyDer()
        )
        let client = AwsLcHttp1TlsHandshaker.create(
            TrustPolicy.pinnedPublicKeys([http1TlsServerPin()])
        )
        try {
            runTlsHttp1Exchange(server, client)
        } finally {
            client.close()
            server.close()
        }
    }
}

private func isTlsFallbackHttp11(value: HttpNegotiatedProtocol): Bool {
    match (value) { case HttpNegotiatedProtocol.Http11 => true; case _ => false }
}

private func runTlsHttp1Exchange(
    server: AwsLcHttp1ServerTlsHandshaker,
    client: AwsLcHttp1TlsHandshaker
): Unit {
        let (clientTransport, serverTransport) = MemoryTransport.pair(capacity: 64 * 1024)
        let context = OperationContext(deadline: Some(Deadline.after(3 * Duration.second)))
        let serving = spawn {
            let secured = server.handshake(serverTransport, context)
            serveHttp1Connection(
                secured, TlsServerStaticHandler(), context: context, maximumRequests: 1
            )
        }
        let secured = client.handshake(HostName("example.com"), clientTransport, context)
        let connection = Http1ClientConnection(secured)
        let response = connection.execute(
            HttpRequest.get("https://example.com/secure"), context: context
        ).response
        @Expect(response.status, 200)
        @Expect(response.headers.getFirst("x-wirestack-tls"), Some("http1"))
        response.close()
        connection.close()
        @Expect(serving.get(3 * Duration.second).requestsServed, 1)
}

private func http1TlsServerPin(): SpkiSha256Pin {
    SpkiSha256Pin([
        0xff, 0xa0, 0x19, 0xf8, 0x3b, 0xe3, 0x10, 0x77,
        0x53, 0x96, 0x71, 0xba, 0xc2, 0xeb, 0x76, 0xfa,
        0x5c, 0x00, 0x3a, 0x68, 0x8f, 0xfb, 0x04, 0xe8,
        0x1a, 0x69, 0x57, 0x2e, 0xfe, 0xb9, 0xac, 0x8e
    ])
}

private class TlsServerStaticHandler <: Http1ServerHandler {
    public func handle(request: Http1ServerRequest,
        context: OperationContext): Http1ServerResponse {
        let _ = context
        @Expect(request.head.target, "/secure")
        Http1ServerResponse(HttpResponse(
            200, "OK", ResponseBody.empty(),
            headers: HttpHeaders.builder()
                .add("Content-Length", "0")
                .add("X-Wirestack-TLS", "http1")
                .build()
        ))
    }
}

// Self-signed public test material, valid 2026-08-23 through 2036-08-20.
private func http1TlsTestCertificateDer(): Array<Byte> {
    decodeHttp1TlsBase64(
        "MIIDQzCCAiugAwIBAgIUDZ6pPmV6gcjC9tTovgITROZDWi4wDQYJKoZIhvcNAQELBQAwGjEYMBYGA1UEAwwPaWdub3JlZC5leGFtcGxlMB4XDTI2MDgyMzIwMTkyOFoXDTM2MDgyMDIwMTkyOFowGjEYMBYGA1UEAwwPaWdub3JlZC5leGFtcGxlMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA3+ICzVHaQ8+czxeV/aeg/iAIgwhqYytRVc17/BY3XdLtYSaG9O6wYxtqm5zZvcujcl35vStEEIc6RsXpQxAUzGp6Gq129MTDzdyW5a7x63bWC6Zlh6SpC4zFdt/xGJisJw/HS4LHLXKzQiSwHZPwFN7zOZ0JMAh05BLF4yEOwkbiqYUR3i7z0wVtvUFuL3NAGfZXzXY1HRi+Qfm/h9lbrMmQtm3kBGBmZUh8ASqugcfiCMziYYY1ygZw1MACxJ60nRfvq1wYVZdUmiD2WED4NF0VK58tP/qJ0KnKz/I2g4GcV5Xu1tH/2NYaI8YT2ejIQn6TgwYWN+3HaXe3Q83DQwIDAQABo4GAMH4wHQYDVR0OBBYEFOdUzp+rhoI4EOD+k/HiZeHgTdcEMB8GA1UdIwQYMBaAFOdUzp+rhoI4EOD+k/HiZeHgTdcEMA8GA1UdEwEB/wQFMAMBAf8wKwYDVR0RBCQwIoILZXhhbXBsZS5jb22CDSouZXhhbXBsZS5vcmeHBH8AAAEwDQYJKoZIhvcNAQELBQADggEBALHiaFne/TJfVzznruLWTPKpQV/+dZKhPw8X2umZ1fLd6/sD2xtoeDof2IOx+HqQJuQNFNY8lAHsCb5J72/O5rXBhHHbYxwTL/LuAo9fKbCCwxp10Y5gwPrEcl5T1ZlsAgPTKq10ONwNR03wefE6epejITvX2nCNJUiaf3BWzFiq5xsZXfUHoil/AqAJfqnAgiABoOs/ZxErf0q16Apr4rjFvreAwsiYr1YgJ4aL97j3jCvJUNreGr8TNUBachUSrRvWcOOTaw90eex/6DnvU1EHDknlmcuuzywawVNzrTd10EuHimVfJgo1hRSzXd4deCHKStlYkPKZpwU/M+Al8F0="
    )
}

private func http1TlsTestPrivateKeyDer(): Array<Byte> {
    decodeHttp1TlsBase64(
        "MIIEvwIBADANBgkqhkiG9w0BAQEFAASCBKkwggSlAgEAAoIBAQDf4gLNUdpDz5zPF5X9p6D+IAiDCGpjK1FVzXv8Fjdd0u1hJob07rBjG2qbnNm9y6NyXfm9K0QQhzpGxelDEBTManoarXb0xMPN3JblrvHrdtYLpmWHpKkLjMV23/EYmKwnD8dLgsctcrNCJLAdk/AU3vM5nQkwCHTkEsXjIQ7CRuKphRHeLvPTBW29QW4vc0AZ9lfNdjUdGL5B+b+H2VusyZC2beQEYGZlSHwBKq6Bx+IIzOJhhjXKBnDUwALEnrSdF++rXBhVl1SaIPZYQPg0XRUrny0/+onQqcrP8jaDgZxXle7W0f/Y1hojxhPZ6MhCfpODBhY37cdpd7dDzcNDAgMBAAECggEAKz/5o5l27VerptQbHTPnZYBhtJKJHtxM66L1GzddfcoUIorzUljUCWlP+HzeEYzH5/2gk7tKfFjrWKW+EL8IDY9aRFITY2ipnNjK69cWlBLSedCs133nTDxnHzZW2JYR17/0E7HRcYWxfIsi3KvqGtYRLaWZE0bm8fJweRa3R69WXYsZOYDK1CDMmrGZ572+5thDTVaiQKOOUBPNgucnB894rYtLYs98sb+2h4EUHZ0cQCIBUVdwu6BAFMwiAEtz2CClwA1G2fq59A9mqQXSkj8WaUHUgo9WcExt6pBEb5MPca+BHWz/aqdC9HRKQFBl3kn4h0qEGkLSy0WrMLKm7QKBgQD6fmd1BDrlsgbLoai3NnrnqKVbn8+0vnJjmTTykxeYHQXxBt3fzH+t42crJowQbuLeoO20oUY0VU8eQVh7bWvduucfFqrecLCL6GhhAFxp2dMjgOdvIim3QN9kvTSUlwOYchA43RTA7wWSzUf1+bL1XWs5bUNg5azpN0Btkma5xQKBgQDkzdwslfjcZgOp1QX2oSPOaA1VuOEJnr3+I2SR8FNH+bVwfbrilF5Mm08jHHHgoqgnGZLG7GLIgQAU1PmIr84hB7CE3JM9xXJ3t0jZ7BktfJEHLzog2Dr6vzXGT+yDcd2q1Lr3GL6x18Y+kgv6ieLv047SOBLal4o8iEjj9PZBZwKBgQCEzx4VKZ/8hq4ZquVj9iulxYGemZWrc8n8So+LCTfaO5EZ4JUkgi0zyby6YR6j29bHSLWfLl6lgpGHLgg2sKYfEmhV0FPZyg+griEhROq6aHYMfdy2zHsnoOqQY8yL96E9Y0R8kaLeRBxFYDeGD9S1SMl/0hGGP1+06slrDtMOLQKBgQCGArDviFN/O1zv7u4UOuNO9JDC4Ysk6E4deLth4uHUaURFA88fAImO0vRx+yoTyRE1/XuDeVaOW0gh62/QCDByFh/kYZD4ABqAVeCcivVgN/J1w8qHDD7XOIEViyBbCKktcnWjXmHqphfd9AqCDprVnxKqu98HGvUDaUtQANzvBwKBgQDJkuAOZocXTl77PfxDWfsP57StrsiuL+AvoH2FscRcT19e9T2U4YuCsyVydRM+gjUoJX5VPedIo+/gcvJrQcJIfwzZlqMMEJnYcWjoG8GYVtub9/xxSPmfuyj3GDbXEcirKkmGOmI5hPEP2UIasTUeljm8sHSP2B52kyKmdVGuUg=="
    )
}

private func decodeHttp1TlsBase64(value: String): Array<Byte> {
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
        } else if (byte == b'+') { 62 }
        else if (byte == b'/') { 63 }
        else { throw IllegalArgumentException("invalid HTTP TLS test fixture") }
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
