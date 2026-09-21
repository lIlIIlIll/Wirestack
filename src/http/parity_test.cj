package wirestack.http

import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api

@Test
class HttpParityContractTest {
    @TestCase
    func cookieJarAppliesSecureDomainAndPathBounds(): Unit {
        let jar = CookieJar(maximumCookies: 2)
        jar.put(Cookie("sid", "abc", domain: Some("example.com"), secure: true))
        jar.put(Cookie("theme", "dark", path: "/docs"))

        let secure = HttpUrl.parse("https://example.com/docs/index")
        @Expect(jar.headerFor(secure), "sid=abc; theme=dark")
        let insecure = HttpUrl.parse("http://example.com/docs/index")
        @Expect(jar.headerFor(insecure), "theme=dark")
        let outside = HttpUrl.parse("https://example.com/other")
        @Expect(jar.headerFor(outside), "sid=abc")

        @Expect(jar.acceptSetCookie("fresh=value; Path=/docs; Secure; HttpOnly", secure), true)
        @Expect(jar.headerFor(secure), "theme=dark; fresh=value")
        @Expect(jar.acceptSetCookie("fresh=gone; Path=/docs; Max-Age=0", secure), true)
        @Expect(jar.headerFor(secure), "theme=dark")
    }

    @TestCase
    func multipartAndWebSocketValuesOwnPayloads(): Unit {
        let input = [1u8, 2u8, 3u8]
        let part = MultipartPart("payload", input)
        input[0] = 9u8
        @Expect(part.bytes(), [1u8, 2u8, 3u8])

        let frameInput = [4u8, 5u8]
        let frame = WebSocketFrame(true, WebSocketOpcode.Binary, frameInput)
        frameInput[0] = 8u8
        @Expect(frame.bytes(), [4u8, 5u8])

        let writer = MultipartWriter("wirestack-test")
        writer.add(part)
        @Expect(writer.snapshot().size, 1)
        @Expect(writer.contentType(), "multipart/form-data; boundary=wirestack-test")
        let body = writer.body().open()
        let output = Array<Byte>(512, repeat: 0u8)
        let count = body.read(output)
        body.close()
        @Expect(count > 0)
        @Expect(String.fromUtf8(output[0..26]), "--wirestack-test\r\nContent-")
        @Expect(output[count - 1] == b'\n')
    }

    @TestCase
    func websocketFramesRoundTripAndBoundControlFrames(): Unit {
        let frame = WebSocketFrame(true, WebSocketOpcode.Binary, [1u8, 2u8, 3u8])
        let encoded = frame.encode(maskingKey: Some([9u8, 8u8, 7u8, 6u8]))
        let decoded = WebSocketFrame.decode(encoded)
        @Expect(decoded.fin, true)
        match (decoded.opcode) {
            case WebSocketOpcode.Binary => @Expect(true)
            case _ => @Expect(false)
        }
        @Expect(decoded.bytes(), [1u8, 2u8, 3u8])
        try {
            let _ = WebSocketFrame(false, WebSocketOpcode.Ping, [1u8])
            @Expect(false)
        } catch (_: Exception) { @Expect(true) }
    }

    @TestCase
    func upgradeRequiresConnectionAndUpgradeTokens(): Unit {
        let accepted = HttpUpgrade.negotiate(
            HttpHeaders.builder()
                .add("Connection", "keep-alive, Upgrade")
                .add("Upgrade", "websocket")
                .build(),
            HttpUpgradeProtocol.WebSocket
        )
        @Expect(accepted.accepted)

        let rejected = HttpUpgrade.negotiate(
            HttpHeaders.builder().add("Upgrade", "websocket").build(),
            HttpUpgradeProtocol.WebSocket
        )
        @Expect(!rejected.accepted)
    }

    @TestCase
    func parityHooksRemainProviderNeutral(): Unit {
        let _ = api.OperationContext.background()
        let _ = HttpUpgradeResult(false)
        let _ = CookieSameSite.Strict
        let _ = HttpUpgradeProtocol.H2c
        let policy = DenyHttp2PushPolicy()
        @Expect(!policy.allow(
            HttpUrl.parse("https://example.test/"),
            HttpUrl.parse("https://example.test/pushed"),
            api.OperationContext.background()
        ))
    }
}
