package wirestack.internal.http1

import std.unittest.*
import std.unittest.testmacro.*
import wirestack.http.*

@Test
class Http1HeadParserTest {
    @TestCase
    func requestParsesIncrementallyAndReturnsBodyRemainder(): Unit {
        let parser = Http1RequestHeadParser()
        let wire = "POST /upload?q=1 HTTP/1.1\r\nHost: Example.COM\r\nContent-Length: 4\r\nX-Multi: one\r\nX-Multi: two\r\n\r\nbody".toArray()
        var parsed: ?Http1ParsedRequestHead = None<Http1ParsedRequestHead>
        for (index in 0..wire.size) {
            if (index + 1 < wire.size) {
                let result = parser.feed([wire[index]])
                if (result.isSome()) { parsed = result; break }
            } else {
                parsed = parser.feed([wire[index]])
            }
        }
        // The byte-at-a-time loop completes at the head boundary, so body is supplied separately.
        let result = match (parsed) {
            case Some(value) => value
            case None => throw Exception("request head did not complete")
        }
        @Expect(result.head.method, HttpMethod("POST"))
        @Expect(result.head.target, "/upload?q=1")
        @Expect(result.head.headers.getAll("x-multi"), ["one", "two"])
        @Expect(contentLengthFromHead(result.head.framing), 4)
        @Expect(result.remaining.isEmpty())
    }

    @TestCase
    func oneFeedRetainsBytesAfterTheHead(): Unit {
        let result = requireRequest(Http1RequestHeadParser().feed(
            "GET / HTTP/1.1\r\nHost: example.com\r\n\r\nnext-message".toArray()
        ))
        @Expect(String.fromUtf8(result.remaining), "next-message")
        let copy = result.remaining
        copy[0] = b'X'
        @Expect(String.fromUtf8(result.remaining), "next-message")
    }

    @TestCase
    func responseParsesStatusReasonHeadersAndFraming(): Unit {
        let parser = Http1ResponseHeadParser(HttpMethod("GET"))
        @Expect(parser.feed("HTTP/1.1 200 O".toArray()).isNone())
        let result = requireResponse(parser.feed(
            "K\r\nContent-Length: 5\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n\r\nhello".toArray()
        ))
        @Expect(result.head.status, 200)
        @Expect(result.head.reason, "OK")
        @Expect(result.head.headers.getAll("set-cookie"), ["a=1", "b=2"])
        @Expect(contentLengthFromHead(result.head.framing), 5)
        @Expect(String.fromUtf8(result.remaining), "hello")
    }

    @TestCase
    func acceptsOriginAbsoluteAuthorityAndAsteriskFormsOnlyWhereValid(): Unit {
        let absolute = requireRequest(Http1RequestHeadParser().feed(
            "GET HTTPS://example.com:443/a HTTP/1.1\r\nHost: example.com\r\n\r\n".toArray()
        ))
        @Expect(absolute.head.target, "HTTPS://example.com:443/a")

        let connect = requireRequest(Http1RequestHeadParser().feed(
            "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n".toArray()
        ))
        @Expect(connect.head.target, "example.com:443")

        let options = requireRequest(Http1RequestHeadParser().feed(
            "OPTIONS * HTTP/1.1\r\nHost: example.com\r\n\r\n".toArray()
        ))
        @Expect(options.head.target, "*")
    }

    @TestCase
    func rejectsBareLfObsFoldAndInvalidHeaderSyntax(): Unit {
        expectParseFailure(
            Http1ParseErrorCode.InvalidLineEnding,
            "GET / HTTP/1.1\nHost: example.com\n\n"
        )
        expectParseFailure(
            Http1ParseErrorCode.ObsoleteLineFolding,
            "GET / HTTP/1.1\r\nHost: example.com\r\n folded\r\n\r\n"
        )
        expectParseFailure(
            Http1ParseErrorCode.InvalidHeader,
            "GET / HTTP/1.1\r\nHost : example.com\r\n\r\n"
        )
    }

    @TestCase
    func requiresOneValidHostAndMatchingAbsoluteAuthority(): Unit {
        expectParseFailure(Http1ParseErrorCode.MissingOrDuplicateHost, "GET / HTTP/1.1\r\n\r\n")
        expectParseFailure(
            Http1ParseErrorCode.MissingOrDuplicateHost,
            "GET / HTTP/1.1\r\nHost: a.test\r\nHost: a.test\r\n\r\n"
        )
        expectParseFailure(
            Http1ParseErrorCode.MissingOrDuplicateHost,
            "GET https://a.test/ HTTP/1.1\r\nHost: b.test\r\n\r\n"
        )
        expectParseFailure(
            Http1ParseErrorCode.MissingOrDuplicateHost,
            "CONNECT a.test:443 HTTP/1.1\r\nHost: b.test:443\r\n\r\n"
        )
    }

    @TestCase
    func rejectsInvalidTargetVersionAndBoundViolations(): Unit {
        expectParseFailure(
            Http1ParseErrorCode.InvalidRequestTarget,
            "GET /bad%zz HTTP/1.1\r\nHost: example.com\r\n\r\n"
        )
        expectParseFailure(
            Http1ParseErrorCode.InvalidRequestTarget,
            "GET * HTTP/1.1\r\nHost: example.com\r\n\r\n"
        )
        expectParseFailure(
            Http1ParseErrorCode.InvalidVersion,
            "GET / HTTP/1.0\r\nHost: example.com\r\n\r\n"
        )

        var tooLong = false
        try {
            let _ = Http1RequestHeadParser(limits: HttpLimits(maxHeaderLineBytes: 16))
                .feed("GET /this-is-too-long HTTP/1.1\r\nHost: a.test\r\n\r\n".toArray())
        } catch (error: Http1ParseException) {
            tooLong = isParseCode(error.code, Http1ParseErrorCode.LineTooLong)
        }
        @Expect(tooLong)
    }

    @TestCase
    func completedParserCannotBeReused(): Unit {
        let parser = Http1RequestHeadParser()
        let _ = parser.feed("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n".toArray())
        var rejected = false
        try {
            let _ = parser.feed(Array<Byte>())
        } catch (error: Http1ParseException) {
            rejected = isParseCode(error.code, Http1ParseErrorCode.ParserAlreadyCompleted)
        }
        @Expect(rejected)
    }
}

private func requireRequest(value: ?Http1ParsedRequestHead): Http1ParsedRequestHead {
    match (value) { case Some(result) => result; case None => throw Exception("missing parsed request") }
}

private func requireResponse(value: ?Http1ParsedResponseHead): Http1ParsedResponseHead {
    match (value) { case Some(result) => result; case None => throw Exception("missing parsed response") }
}

private func contentLengthFromHead(value: Http1BodyFraming): Int64 {
    match (value) { case Http1BodyFraming.ContentLength(size) => size; case _ => -1 }
}

private func expectParseFailure(code: Http1ParseErrorCode, wire: String): Unit {
    var matched = false
    try {
        let _ = Http1RequestHeadParser().feed(wire.toArray())
    } catch (error: Http1ParseException) {
        matched = isParseCode(error.code, code)
    }
    @Expect(matched)
}

private func isParseCode(left: Http1ParseErrorCode, right: Http1ParseErrorCode): Bool {
    match ((left, right)) {
        case (Http1ParseErrorCode.HeaderTooLarge, Http1ParseErrorCode.HeaderTooLarge) => true
        case (Http1ParseErrorCode.LineTooLong, Http1ParseErrorCode.LineTooLong) => true
        case (Http1ParseErrorCode.InvalidLineEnding, Http1ParseErrorCode.InvalidLineEnding) => true
        case (Http1ParseErrorCode.InvalidStartLine, Http1ParseErrorCode.InvalidStartLine) => true
        case (Http1ParseErrorCode.InvalidVersion, Http1ParseErrorCode.InvalidVersion) => true
        case (Http1ParseErrorCode.InvalidStatus, Http1ParseErrorCode.InvalidStatus) => true
        case (Http1ParseErrorCode.InvalidRequestTarget, Http1ParseErrorCode.InvalidRequestTarget) => true
        case (Http1ParseErrorCode.InvalidHeader, Http1ParseErrorCode.InvalidHeader) => true
        case (Http1ParseErrorCode.ObsoleteLineFolding, Http1ParseErrorCode.ObsoleteLineFolding) => true
        case (Http1ParseErrorCode.MissingOrDuplicateHost, Http1ParseErrorCode.MissingOrDuplicateHost) => true
        case (Http1ParseErrorCode.ParserAlreadyCompleted, Http1ParseErrorCode.ParserAlreadyCompleted) => true
        case _ => false
    }
}
