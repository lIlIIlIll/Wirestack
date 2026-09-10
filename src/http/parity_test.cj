package wirestack.http

import std.unittest.*
import std.unittest.testmacro.*
import wirestack as api

@Test
class HttpParityContractTest {
    @TestCase
    func cookieJarNeverEmitsUnscopedOrOutOfScopeCredentials(): Unit {
        let jar = CookieJar(maximumCookies: 3)
        jar.put(Cookie("sid", "abc", domain: Some("Example.COM"),
            path: "/docs", secure: true))
        jar.put(Cookie("unscoped", "secret"))

        @Expect(
            jar.headerFor(HttpUrl.parse("https://example.com/docs?view=full")),
            "sid=abc"
        )
        @Expect(
            jar.headerFor(HttpUrl.parse("https://api.example.com/docs/index")),
            "sid=abc"
        )
        @Expect(jar.headerFor(HttpUrl.parse("https://notexample.com/docs/index")), "")
        @Expect(jar.headerFor(HttpUrl.parse("https://example.com/docsets/index")), "")
        @Expect(jar.headerFor(HttpUrl.parse("http://example.com/docs/index")), "")
        @Expect(jar.headerFor(HttpUrl.parse("https://other.test/docs/index")), "")
    }

    @TestCase
    func cookieMetadataRejectsHeaderInjectionAndAmbiguousScopes(): Unit {
        @Expect(parityIllegalArgument({=>
            let _ = Cookie("bad name", "value", domain: Some("example.com"))
        }))
        @Expect(parityIllegalArgument({=>
            let _ = Cookie("sid", "value; injected=yes", domain: Some("example.com"))
        }))
        @Expect(parityIllegalArgument({=>
            let _ = Cookie("sid", "value", domain: Some("example.com/path"))
        }))
        @Expect(parityIllegalArgument({=>
            let _ = Cookie("sid", "value", domain: Some(".example.com"))
        }))
        @Expect(parityIllegalArgument({=>
            let _ = Cookie("sid", "value", domain: Some("example.com"), path: "docs")
        }))
        @Expect(parityIllegalArgument({=>
            let _ = Cookie("sid", "value", domain: Some("example.com"),
                sameSite: CookieSameSite.None)
        }))
    }

    @TestCase
    func cookieJarEnforcesCapacityAndClosedLifecycle(): Unit {
        let jar = CookieJar(maximumCookies: 2)
        jar.put(Cookie("a", "1", domain: Some("example.com")))
        jar.put(Cookie("b", "2", domain: Some("example.com")))
        jar.put(Cookie("c", "3", domain: Some("example.com")))
        @Expect(jar.snapshot().size, 2)
        @Expect(jar.headerFor(HttpUrl.parse("https://example.com/")), "b=2; c=3")

        jar.close()
        jar.close()
        @Expect(jar.isClosed())
        @Expect(parityIllegalState({=>
            let _ = jar.headerFor(HttpUrl.parse("https://example.com/"))
        }))
        @Expect(parityIllegalState({=> let _ = jar.snapshot() }))
        @Expect(parityIllegalState({=>
            jar.put(Cookie("d", "4", domain: Some("example.com")))
        }))
    }

    @TestCase
    func persistenceFailureDoesNotReplaceOrEvictVisibleCookies(): Unit {
        let jar = CookieJar(maximumCookies: 1, store: Some(RejectingCookieStore()))
        let url = HttpUrl.parse("https://example.com/")
        @Expect(parityIllegalState({=>
            jar.put(Cookie("sid", "replacement", domain: Some("example.com")))
        }))
        @Expect(jar.headerFor(url), "sid=original")
        @Expect(parityIllegalState({=>
            jar.put(Cookie("other", "new", domain: Some("example.com")))
        }))
        @Expect(jar.headerFor(url), "sid=original")
    }

    @TestCase
    func cookieHeaderPrioritizesLongerPathsAndPreservesEqualPathOrder(): Unit {
        let jar = CookieJar()
        jar.put(Cookie("sid", "root", domain: Some("example.com")))
        jar.put(Cookie("sid", "docs", domain: Some("example.com"), path: "/docs"))
        jar.put(Cookie("peer", "first", domain: Some("example.com"), path: "/docs"))
        jar.put(Cookie("sid", "updated", domain: Some("example.com"), path: "/docs"))
        jar.put(Cookie("sid", "deep", domain: Some("example.com"), path: "/docs/api"))
        @Expect(jar.headerFor(HttpUrl.parse("https://example.com/docs/api/page")),
            "sid=deep; sid=updated; peer=first; sid=root")
    }

    @TestCase
    func multipartBoundaryRejectsHttpTokenBytesOutsideMimeSyntax(): Unit {
        for (value in 0..128) {
            let byte = UInt8(value)
            let allowed = (byte >= b'0' && byte <= b'9') ||
                (byte >= b'A' && byte <= b'Z') || (byte >= b'a' && byte <= b'z') ||
                byte == b'\'' || byte == b'+' || byte == b'_' ||
                byte == b'-' || byte == b'.'
            let boundary = String.fromUtf8([byte])
            @Expect(parityIllegalArgument({=> let _ = MultipartWriter(boundary) }),
                !allowed)
        }
        @Expect(MultipartWriter("safe+_'.-123").contentType(),
            "multipart/form-data; boundary=safe+_'.-123")
    }

    @TestCase
    func multipartMetadataAndRetentionFailClosedAtBounds(): Unit {
        let input = [1u8, 2u8, 3u8]
        let part = MultipartPart("payload", input)
        input[0] = 9u8
        @Expect(part.bytes(), [1u8, 2u8, 3u8])

        let payloadBound = MultipartWriter("wirestack-test", maximumPayloadBytes: 2)
        @Expect(parityIllegalState({=> payloadBound.add(part) }))

        let countBound = MultipartWriter("wirestack-test", maximumParts: 1)
        countBound.add(part)
        @Expect(parityIllegalState({=> countBound.add(part) }))

        @Expect(parityIllegalArgument({=>
            let _ = MultipartWriter("unsafe;parameter")
        }))
        @Expect(parityIllegalArgument({=>
            let _ = MultipartPart("payload", [1u8], contentType: "text")
        }))
        let deleteMetadata = String.fromUtf8([b'b', b'a', b'd', 0x7fu8])
        @Expect(parityIllegalArgument({=>
            let _ = MultipartPart(deleteMetadata, [1u8])
        }))
    }

    @TestCase
    func upgradeHeaderMatcherRejectsMissingAndInvalidTokens(): Unit {
        let matched = HttpUpgrade.matchRequestHeaders(
            HttpHeaders.builder()
                .add("Connection", "keep-alive, Upgrade")
                .add("Upgrade", "websocket")
                .build(),
            HttpUpgradeProtocol.WebSocket
        )
        @Expect(matched.matched)
        @Expect(matched.protocolName, Some("websocket"))

        let missingConnection = HttpUpgrade.matchRequestHeaders(
            HttpHeaders.builder().add("Upgrade", "websocket").build(),
            HttpUpgradeProtocol.WebSocket
        )
        @Expect(!missingConnection.matched)
        let invalidCustom = HttpUpgrade.matchRequestHeaders(
            HttpHeaders.builder()
                .add("Connection", "Upgrade")
                .add("Upgrade", "")
                .build(),
            HttpUpgradeProtocol.Custom("")
        )
        @Expect(!invalidCustom.matched)
    }

    @TestCase
    func websocketControlFramesAndPushDefaultStayBounded(): Unit {
        let frameInput = [4u8, 5u8]
        let frame = WebSocketFrame(true, WebSocketOpcode.Binary, frameInput)
        frameInput[0] = 8u8
        @Expect(frame.bytes(), [4u8, 5u8])
        @Expect(parityIllegalArgument({=>
            let _ = WebSocketFrame(false, WebSocketOpcode.Ping, [1u8])
        }))

        let policy = DenyHttp2PushPolicy()
        @Expect(!policy.allow(
            HttpUrl.parse("https://example.test/"),
            HttpUrl.parse("https://example.test/pushed"),
            api.OperationContext.background()
        ))
    }
}

private func parityIllegalArgument(action: () -> Unit): Bool {
    try {
        action()
        false
    } catch (_: IllegalArgumentException) {
        true
    }
}

private func parityIllegalState(action: () -> Unit): Bool {
    try {
        action()
        false
    } catch (_: IllegalStateException) {
        true
    }
}

private class RejectingCookieStore <: CookieStore {
    public func load(): Array<Cookie> {
        [Cookie("sid", "original", domain: Some("example.com"))]
    }

    public func save(_: Cookie): Unit {
        throw IllegalStateException("injected persistence failure")
    }

    public func remove(_: String, _: ?String, _: String): Unit {
        throw IllegalStateException("unexpected persistence removal")
    }
}
