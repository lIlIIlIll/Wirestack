package wirestack.http

import std.unittest.*
import std.unittest.testmacro.*

@Test
class HttpRedirectPolicyTest {
    @TestCase
    func rewritesPostOn302AndRemovesBodyHeaders(): Unit {
        let request = HttpRequest(
            HttpMethod("POST"),
            HttpUrl.parse("https://example.com/start"),
            headers: HttpHeaders.builder()
                .add("Content-Type", "text/plain")
                .add("Content-Length", "4")
                .build(),
            body: RequestBody.string("data")
        )
        let next = requireRedirect(HttpRedirectPolicy().nextRequest(
            request,
            redirectResponse(302, "/next")
        ))
        @Expect(next.method.value, "GET")
        @Expect(next.url.toString(), "https://example.com/next")
        @Expect(next.body.contentLength, Some(0))
        @Expect(!next.headers.contains("content-type"))
        @Expect(!next.headers.contains("content-length"))
    }

    @TestCase
    func stripsSensitiveHeadersOnlyAcrossOrigins(): Unit {
        let headers = HttpHeaders.builder()
            .add("Authorization", "secret")
            .add("Cookie", "session=x")
            .add("X-Trace", "keep")
            .build()
        let request = HttpRequest(HttpMethod("GET"), HttpUrl.parse("https://a.test/start"), headers: headers)
        let same = requireRedirect(HttpRedirectPolicy().nextRequest(
            request, redirectResponse(307, "https://a.test/next")
        ))
        @Expect(same.headers.contains("authorization"))
        @Expect(same.headers.contains("cookie"))

        let cross = requireRedirect(HttpRedirectPolicy().nextRequest(
            request, redirectResponse(307, "https://b.test/next")
        ))
        @Expect(!cross.headers.contains("authorization"))
        @Expect(!cross.headers.contains("cookie"))
        @Expect(cross.headers.getFirst("x-trace"), Some("keep"))
    }

    @TestCase
    func rejectsDowngradeLimitAndOneShotReplay(): Unit {
        expectRedirectError(HttpRedirectErrorCode.InsecureDowngrade, { =>
            let _ = HttpRedirectPolicy().nextRequest(
                HttpRequest.get("https://secure.test/"),
                redirectResponse(301, "http://secure.test/")
            )
        })
        expectRedirectError(HttpRedirectErrorCode.TooManyRedirects, { =>
            let _ = HttpRedirectPolicy(maximumRedirects: 1).nextRequest(
                HttpRequest.get("http://a.test/"),
                redirectResponse(301, "/again"),
                redirectsFollowed: 1
            )
        })
        let stream = RequestBody.string("x").open()
        expectRedirectError(HttpRedirectErrorCode.BodyNotReplayable, { =>
            let _ = HttpRedirectPolicy().nextRequest(
                HttpRequest(HttpMethod("PUT"), HttpUrl.parse("http://a.test/"),
                    body: RequestBody.oneShot(stream)),
                redirectResponse(307, "/again")
            )
        })
        stream.close()

        let emptyStream = RequestBody.empty().open()
        expectRedirectError(HttpRedirectErrorCode.BodyNotReplayable, { =>
            let _ = HttpRedirectPolicy().nextRequest(
                HttpRequest(HttpMethod("GET"), HttpUrl.parse("http://a.test/"),
                    body: RequestBody.oneShot(emptyStream)),
                redirectResponse(308, "/again")
            )
        })
        emptyStream.close()
    }

    @TestCase
    func resolvesSchemeRelativeAndQueryOnlyLocations(): Unit {
        let request = HttpRequest.get("https://a.test/path?old=1")
        let schemeRelative = requireRedirect(HttpRedirectPolicy().nextRequest(
            request, redirectResponse(308, "//b.test/next")
        ))
        @Expect(schemeRelative.url.toString(), "https://b.test/next")
        let queryOnly = requireRedirect(HttpRedirectPolicy().nextRequest(
            request, redirectResponse(308, "?new=2")
        ))
        @Expect(queryOnly.url.toString(), "https://a.test/path?new=2")
    }

    @TestCase
    func resolvesRelativePathsAndRemovesDotSegments(): Unit {
        let request = HttpRequest.get("https://a.test/one/two/start")
        let sibling = requireRedirect(HttpRedirectPolicy().nextRequest(
            request, redirectResponse(308, "next?ok=1")
        ))
        @Expect(sibling.url.toString(), "https://a.test/one/two/next?ok=1")
        let parent = requireRedirect(HttpRedirectPolicy().nextRequest(
            request, redirectResponse(308, "../final")
        ))
        @Expect(parent.url.toString(), "https://a.test/one/final")
        let rooted = requireRedirect(HttpRedirectPolicy().nextRequest(
            request, redirectResponse(308, "/a/./b/../c")
        ))
        @Expect(rooted.url.toString(), "https://a.test/a/c")
    }
}

private func redirectResponse(status: Int64, location: String): HttpResponse {
    HttpResponse(
        status,
        "Redirect",
        ResponseBody.empty(),
        headers: HttpHeaders.builder().add("Location", location).add("Content-Length", "0").build()
    )
}

private func requireRedirect(value: ?HttpRequest): HttpRequest {
    match (value) { case Some(request) => request; case None => throw Exception("expected redirect") }
}

private func expectRedirectError(code: HttpRedirectErrorCode, action: () -> Unit): Unit {
    var matched = false
    try {
        action()
    } catch (error: HttpRedirectException) {
        matched = sameRedirectCode(error.code, code)
    }
    @Expect(matched)
}

private func sameRedirectCode(left: HttpRedirectErrorCode, right: HttpRedirectErrorCode): Bool {
    match ((left, right)) {
        case (HttpRedirectErrorCode.TooManyRedirects, HttpRedirectErrorCode.TooManyRedirects) => true
        case (HttpRedirectErrorCode.InsecureDowngrade, HttpRedirectErrorCode.InsecureDowngrade) => true
        case (HttpRedirectErrorCode.InvalidLocation, HttpRedirectErrorCode.InvalidLocation) => true
        case (HttpRedirectErrorCode.BodyNotReplayable, HttpRedirectErrorCode.BodyNotReplayable) => true
        case _ => false
    }
}
