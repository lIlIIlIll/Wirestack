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
