package wirestack.http

import std.unittest.*
import std.unittest.testmacro.*

@Test
class HttpModelTest {
    @TestCase
    func methodSupportsStandardAndExtensionTokens(): Unit {
        @Expect(HttpMethod("GET").value, "GET")
        @Expect(HttpMethod("PURGE").toString(), "PURGE")
        @Expect(HttpMethod("GET"), HttpMethod("GET"))

        var rejected = false
        try {
            let _ = HttpMethod("GET /admin")
        } catch (_: IllegalArgumentException) {
            rejected = true
        }
        @Expect(rejected)
    }

    @TestCase
    func headersPreserveOrderAndMultipleValues(): Unit {
        let headers = HttpHeaders.builder()
            .add("Set-Cookie", "a=1")
            .add("set-cookie", "b=2")
            .add("Content-Type", "text/plain")
            .build()

        @Expect(headers.size, 3)
        @Expect(headers.contains("CONTENT-TYPE"))
        @Expect(headers.getFirst("SET-cookie"), Some("a=1"))
        @Expect(headers.getAll("set-cookie"), ["a=1", "b=2"])
        @Expect(headers.entries[0].name, "Set-Cookie")
        @Expect(headers.entries[1].name, "set-cookie")
    }

    @TestCase
    func headersOwnTheirInputAndOutputArrays(): Unit {
        let input = [HttpHeader("X-Test", "original")]
        let headers = HttpHeaders(entries: input)
        input[0] = HttpHeader("X-Test", "changed")
        let output = headers.entries
        output[0] = HttpHeader("X-Test", "also-changed")

        @Expect(headers.getFirst("x-test"), Some("original"))
    }

    @TestCase
    func builderSetAndRemoveUseCaseInsensitiveNames(): Unit {
        let headers = HttpHeaders.builder()
            .add("Cache-Control", "private")
            .add("cache-control", "no-store")
            .set("CACHE-CONTROL", "max-age=0")
            .add("X-Remove", "yes")
            .remove("x-remove")
            .build()

        @Expect(headers.getAll("cache-control"), ["max-age=0"])
        @Expect(!headers.contains("X-REMOVE"))
    }

    @TestCase
    func rejectsInjectionAndInvalidNames(): Unit {
        for (entry in [
            HttpHeaderInput("Bad Name", "value"),
            HttpHeaderInput("X-Test", "safe\r\nInjected: yes"),
            HttpHeaderInput("X-Test", "nul\u{0000}value")
        ]) {
            var rejected = false
            try {
                let _ = HttpHeader(entry.name, entry.value)
            } catch (_: IllegalArgumentException) {
                rejected = true
            }
            @Expect(rejected)
        }
    }

    @TestCase
    func enforcesCountLineAndTotalLimits(): Unit {
        expectHeaderFailure(HttpLimits(maxHeaderCount: 1), [
            HttpHeader("A", "1"), HttpHeader("B", "2")
        ])
        expectHeaderFailure(HttpLimits(maxHeaderLineBytes: 8), [
            HttpHeader("Long", "value")
        ])
        expectHeaderFailure(HttpLimits(maxHeaderLineBytes: 8, maxHeaderBytes: 10), [
            HttpHeader("A", "1"), HttpHeader("B", "2")
        ])
    }

    @TestCase
    func urlNormalizesSchemeHostAndDefaultTarget(): Unit {
        let url = HttpUrl.parse("HTTPS://Example.COM")

        @Expect(url.scheme, "https")
        @Expect(url.host, "example.com")
        @Expect(url.port, 443)
        @Expect(!url.explicitPort)
        @Expect(url.authority, "example.com")
        @Expect(url.requestTarget, "/")
        @Expect(url.toString(), "https://example.com/")
    }

    @TestCase
    func urlPreservesExplicitPortPathAndQuery(): Unit {
        let url = HttpUrl.parse("http://Example.com:8080/a%20b?q=one%2Ftwo")

        @Expect(url.port, 8080)
        @Expect(url.explicitPort)
        @Expect(url.authority, "example.com:8080")
        @Expect(url.requestTarget, "/a%20b?q=one%2Ftwo")
    }

    @TestCase
    func urlRequiresBracketedIpv6AndKeepsQueryOnlyTargetValid(): Unit {
        let ipv6 = HttpUrl.parse("https://[2001:DB8::1]:8443?ready=yes")

        @Expect(ipv6.host, "2001:db8::1")
        @Expect(ipv6.authority, "[2001:db8::1]:8443")
        @Expect(ipv6.requestTarget, "/?ready=yes")
    }

    @TestCase
    func urlRejectsAmbiguousAndUnsafeInputs(): Unit {
        for (value in [
            "ftp://example.com/",
            "https://user@example.com/",
            "https://2001:db8::1/",
            "https://[1::2::3]/",
            "https://[1:2:3]/",
            "https://999.1.1.1/",
            "https://01.2.3.4/",
            "https://example.com:0/",
            "https://example.com:65536/",
            "https://example.com/bad path",
            "https://example.com/%zz",
            "https://example.com/#fragment",
            "https://例子.test/"
        ]) {
            var rejected = false
            try {
                let _ = HttpUrl.parse(value)
            } catch (_: IllegalArgumentException) {
                rejected = true
            }
            @Expect(rejected)
        }
    }

    @TestCase
    func trailerRejectsRoutingAndFramingFields(): Unit {
        let trailer = HttpTrailer(headers: HttpHeaders.builder().add("Digest", "sha-256=value").build())
        @Expect(trailer.headers.getFirst("digest"), Some("sha-256=value"))

        for (name in ["Content-Length", "Transfer-Encoding", "Host", "Connection", "Trailer", "Upgrade"]) {
            var rejected = false
            try {
                let _ = HttpTrailer(headers: HttpHeaders.builder().add(name, "value").build())
            } catch (_: IllegalArgumentException) {
                rejected = true
            }
            @Expect(rejected)
        }
    }
}

private struct HttpHeaderInput {
    let name: String
    let value: String
    init(name: String, value: String) { this.name = name; this.value = value }
}

private func expectHeaderFailure(limits: HttpLimits, entries: Array<HttpHeader>): Unit {
    var rejected = false
    try {
        let _ = HttpHeaders(entries: entries, limits: limits)
    } catch (_: IllegalArgumentException) {
        rejected = true
    }
    @Expect(rejected)
}
