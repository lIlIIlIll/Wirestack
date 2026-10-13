package wirestack.http

import std.unittest.*
import std.unittest.testmacro.*

@Test
class WebSocketUrlTest {
    @TestCase
    func schemesRetainAuthorityTargetsAndExplicitPorts(): Unit {
        for ((value, scheme, host, port, explicitPort, authority, target) in [
            ("WS://EXAMPLE.TEST", "ws", "example.test", 80u16, false, "example.test", "/"),
            ("Wss://Example.Test?x=%2f", "wss", "example.test", 443u16, false, "example.test", "/?x=%2f"),
            ("ws://192.0.2.1:00080/a%2Fb?q=%23", "ws", "192.0.2.1", 80u16, true, "192.0.2.1:80", "/a%2Fb?q=%23"),
            ("wss://[2001:DB8::1]:443/path?", "wss", "2001:db8::1", 443u16, true, "[2001:db8::1]:443", "/path?"),
            ("ws://[::1]:65535/", "ws", "::1", 65535u16, true, "[::1]:65535", "/"),
            ("wss://[::ffff:192.0.2.1]/?a=b", "wss", "::ffff:192.0.2.1", 443u16, false, "[::ffff:192.0.2.1]", "/?a=b")
        ]) {
            let parsed = WebSocketUrl.parse(value)
            @Expect(parsed.scheme, scheme)
            @Expect(parsed.host, host)
            @Expect(parsed.port, port)
            @Expect(parsed.explicitPort, explicitPort)
            @Expect(parsed.authority, authority)
            @Expect(parsed.requestTarget, target)
            @Expect(parsed.toString(), "${scheme}://${authority}${target}")
        }
    }

    @TestCase
    func rejectsUnsafeAuthorityTargetAndUnsupportedSchemes(): Unit {
        for (value in ["", "example.test/a", "ws:/example.test", "http://example.test/", "https://example.test/",
            "ftp://example.test/", "ws:///", "ws://user@example.test/", "wss://user:secret@example.test/",
            "ws://example.test/#fragment", "ws://example.test/#", "ws://example.test/a b", "ws://example.test/a\\b",
            "ws://example.test/a" + String.fromUtf8([10u8]), "ws://example.test/é", "ws://example.test/%", "ws://example.test/%0", "ws://example.test/%GG",
            "ws://bad_label/", "ws://exa%6dple.test/", "ws://127.01.0.1/", "ws://256.0.0.1/", "ws://example.test:0/",
            "ws://example.test:65536/", "ws://example.test:-1/", "ws://example.test:/", "ws://2001:db8::1/",
            "ws://[::1/", "ws://[::1]suffix/", "ws://[2001::db8::1]/", "ws://[fe80::1%25eth0]/"]) {
            @AssertThrows[IllegalArgumentException](WebSocketUrl.parse(value))
        }
    }

    @TestCase
    func enforcesOriginalByteBoundWithoutSchemeProjectionPenalty(): Unit {
        let prefix = "wss://example.test/"
        let value = prefix + "a" * (8192 - prefix.size)
        let parsed = WebSocketUrl.parse(value)
        @Expect(parsed.requestTarget, "/" + "a" * (8192 - prefix.size))
        @AssertThrows[IllegalArgumentException](WebSocketUrl.parse(value + "a"))
    }

    @TestCase
    func ordinaryHttpParsingStillRejectsWebSocketSchemes(): Unit {
        @AssertThrows[IllegalArgumentException](HttpUrl.parse("ws://example.test/socket"))
        @AssertThrows[IllegalArgumentException](HttpUrl.parse("wss://example.test/socket"))
        @Expect(HttpUrl.parse("https://example.test/socket").port, 443u16)
    }

    @TestCase
    func deterministicOctetCorpusPreservesEscapesAndRejectsUnsafeRawTargets(): Unit {
        let digits = "0123456789ABCDEF"
        for (value in 0..256) {
            let encoded = "%" + String.fromUtf8([digits[value / 16], digits[value % 16]])
            for (scheme in ["ws", "wss"]) {
                let target = "/" + encoded + "?q=" + encoded
                @Expect(WebSocketUrl.parse(scheme + "://example.test" + target).requestTarget, target)
                if (value < 128) {
                    let raw = String.fromUtf8([UInt8(value)])
                    let url = scheme + "://example.test/" + raw
                    let rejected = value <= 32 || value == 34 || value == 35 || value == 37 || value == 60 ||
                        value == 62 || value == 91 || value == 92 || value == 93 || value == 94 || value == 96 ||
                        value == 123 || value == 124 || value == 125 || value == 127
                    if (rejected) { @AssertThrows[IllegalArgumentException](WebSocketUrl.parse(url)) }
                    else { @Expect(WebSocketUrl.parse(url).requestTarget, "/" + raw) }
                }
            }
        }
    }
}
