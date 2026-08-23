package wirestack.internal.http1

import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.http_model.*

@Test
class Http1FramingTest {
    @TestCase
    func requestUsesOneSharedEmptyLengthOrChunkedDecision(): Unit {
        @Expect(isEmpty(resolveRequestFraming(HttpHeaders())))
        @Expect(contentLength(resolveRequestFraming(headers("Content-Length", "42"))), 42)
        @Expect(isChunked(resolveRequestFraming(headers("Transfer-Encoding", " chunked "))))
    }

    @TestCase
    func identicalContentLengthsAreAcceptedAcrossFieldsAndLists(): Unit {
        let values = HttpHeaders.builder()
            .add("Content-Length", "7")
            .add("content-length", "7, 7")
            .build()

        @Expect(contentLength(resolveRequestFraming(values)), 7)
    }

    @TestCase
    func conflictingOrInvalidContentLengthsAreRejected(): Unit {
        expectFramingError(
            Http1FramingErrorCode.ConflictingContentLength,
            HttpHeaders.builder().add("Content-Length", "5").add("Content-Length", "6").build()
        )
        for (value in ["", "+1", "-1", "1x", "9223372036854775808", "1,"]) {
            expectFramingError(Http1FramingErrorCode.InvalidContentLength, headers("Content-Length", value))
        }
    }

    @TestCase
    func contentLengthAndTransferEncodingNeverCoexist(): Unit {
        let values = HttpHeaders.builder()
            .add("Content-Length", "5")
            .add("Transfer-Encoding", "chunked")
            .build()
        expectFramingError(Http1FramingErrorCode.ContentLengthWithTransferEncoding, values)
    }

    @TestCase
    func ambiguousTransferEncodingIsRejected(): Unit {
        for (value in ["gzip", "chunked, gzip", "gzip, chunked", "chunked, chunked", ",chunked"]) {
            expectFramingError(Http1FramingErrorCode.AmbiguousTransferEncoding, headers("Transfer-Encoding", value))
        }
    }

    @TestCase
    func responseHandlesHeadStatusesConnectAndCloseDelimiting(): Unit {
        @Expect(isEmpty(resolveResponseFraming(headers("Content-Length", "99"), 200, HttpMethod("HEAD"))))
        @Expect(isEmpty(resolveResponseFraming(HttpHeaders(), 103, HttpMethod("GET"))))
        @Expect(isEmpty(resolveResponseFraming(HttpHeaders(), 204, HttpMethod("GET"))))
        @Expect(isEmpty(resolveResponseFraming(HttpHeaders(), 304, HttpMethod("GET"))))
        @Expect(isTunnel(resolveResponseFraming(HttpHeaders(), 200, HttpMethod("CONNECT"))))
        @Expect(isCloseDelimited(resolveResponseFraming(HttpHeaders(), 200, HttpMethod("GET"))))
        @Expect(contentLength(resolveResponseFraming(headers("Content-Length", "8"), 200, HttpMethod("GET"))), 8)
    }

    @TestCase
    func bodylessAndSuccessfulConnectResponsesRejectFramingFields(): Unit {
        expectResponseFramingError(103, HttpMethod("GET"), headers("Content-Length", "1"))
        expectResponseFramingError(204, HttpMethod("GET"), headers("Transfer-Encoding", "chunked"))
        expectResponseFramingError(200, HttpMethod("CONNECT"), headers("Content-Length", "1"))
    }
}

private func headers(name: String, value: String): HttpHeaders {
    HttpHeaders.builder().add(name, value).build()
}

private func contentLength(framing: Http1BodyFraming): Int64 {
    match (framing) {
        case Http1BodyFraming.ContentLength(value) => value
        case _ => -1
    }
}

private func isEmpty(framing: Http1BodyFraming): Bool {
    match (framing) { case Http1BodyFraming.Empty => true; case _ => false }
}

private func isChunked(framing: Http1BodyFraming): Bool {
    match (framing) { case Http1BodyFraming.Chunked => true; case _ => false }
}

private func isCloseDelimited(framing: Http1BodyFraming): Bool {
    match (framing) { case Http1BodyFraming.CloseDelimited => true; case _ => false }
}

private func isTunnel(framing: Http1BodyFraming): Bool {
    match (framing) { case Http1BodyFraming.Tunnel => true; case _ => false }
}

private func expectFramingError(expected: Http1FramingErrorCode, headers: HttpHeaders): Unit {
    var matched = false
    try {
        let _ = resolveRequestFraming(headers)
    } catch (error: Http1FramingException) {
        matched = sameCode(error.code, expected)
    }
    @Expect(matched)
}

private func sameCode(left: Http1FramingErrorCode, right: Http1FramingErrorCode): Bool {
    match ((left, right)) {
        case (Http1FramingErrorCode.ConflictingContentLength, Http1FramingErrorCode.ConflictingContentLength) => true
        case (Http1FramingErrorCode.InvalidContentLength, Http1FramingErrorCode.InvalidContentLength) => true
        case (Http1FramingErrorCode.ContentLengthWithTransferEncoding, Http1FramingErrorCode.ContentLengthWithTransferEncoding) => true
        case (Http1FramingErrorCode.AmbiguousTransferEncoding, Http1FramingErrorCode.AmbiguousTransferEncoding) => true
        case (Http1FramingErrorCode.ForbiddenBodyFraming, Http1FramingErrorCode.ForbiddenBodyFraming) => true
        case _ => false
    }
}

private func expectResponseFramingError(status: UInt16, method: HttpMethod, headers: HttpHeaders): Unit {
    var rejected = false
    try {
        let _ = resolveResponseFraming(headers, status, method)
    } catch (error: Http1FramingException) {
        rejected = sameCode(error.code, Http1FramingErrorCode.ForbiddenBodyFraming)
    }
    @Expect(rejected)
}
