package wirestack.internal.http2

import std.unittest.*
import std.unittest.testmacro.*
import wirestack.internal.http_model.*

@Test
class Http2ClientMappingTest {
    @TestCase
    func requestMapsOrderedPseudoFieldsAuthorityAndSensitiveHeaders(): Unit {
        let request = HttpRequest(
            HttpMethod("POST"), HttpUrl.parse("https://example.com/upload?q=1"),
            headers: HttpHeaders.builder()
                .add("Host", "EXAMPLE.com:443")
                .add("X-Test", "yes")
                .add("Authorization", "secret")
                .build(),
            body: RequestBody.string("abc")
        )
        let plan = mapHttp2ClientRequest(request)
        let fields = plan.initialHeaders
        expectMappingField(fields, 0, ":method", "POST")
        expectMappingField(fields, 1, ":scheme", "https")
        expectMappingField(fields, 2, ":authority", "EXAMPLE.com:443")
        expectMappingField(fields, 3, ":path", "/upload?q=1")
        expectMappingField(fields, 4, "x-test", "yes")
        expectMappingField(fields, 5, "authorization", "secret")
        expectMappingField(fields, 6, "content-length", "3")
        @Expect(fields.size, 7)
        @Expect(isNeverIndexedMapping(fields[5].mode))
        @Expect(!plan.endStreamOnHeaders)
    }

    @TestCase
    func connectUsesOnlyMethodAndAuthorityPseudoFields(): Unit {
        let plan = mapHttp2ClientRequest(HttpRequest(
            HttpMethod("CONNECT"), HttpUrl.parse("https://example.com:8443/")
        ))
        let fields = plan.initialHeaders
        expectMappingField(fields, 0, ":method", "CONNECT")
        expectMappingField(fields, 1, ":authority", "example.com:8443")
        @Expect(fields.size, 2)
        @Expect(plan.endStreamOnHeaders)
    }

    @TestCase
    func requestRejectsAuthorityFramingAndConnectionAmbiguity(): Unit {
        expectMappingError(Http2MessageErrorCode.InvalidHeader, { =>
            let _ = mapHttp2ClientRequest(requestWithHeader("Host", "other.test"))
        })
        expectMappingError(Http2MessageErrorCode.ForbiddenConnectionHeader, { =>
            let _ = mapHttp2ClientRequest(requestWithHeader("Connection", "close"))
        })
        expectMappingError(Http2MessageErrorCode.InvalidHeader, { =>
            let _ = mapHttp2ClientRequest(requestWithHeader("TE", "gzip"))
        })
        expectMappingError(Http2MessageErrorCode.InvalidContentLength, { =>
            let request = HttpRequest(
                HttpMethod("POST"), HttpUrl.parse("https://example.com/"),
                headers: HttpHeaders.builder().add("Content-Length", "2").build(),
                body: RequestBody.string("abc")
            )
            let _ = mapHttp2ClientRequest(request)
        })
        expectMappingError(Http2MessageErrorCode.InvalidHeader, { =>
            let _ = mapHttp2ClientRequest(requestWithHeader("Trailer", "Content-Length"))
        })
    }

    @TestCase
    func requestHeaderListHonorsHttp2BoundsBeforeHpackMutation(): Unit {
        let request = requestWithHeader("X-One", "1")
        expectMappingError(Http2MessageErrorCode.InvalidHeader, { =>
            let _ = mapHttp2ClientRequest(request, http2Limits: Http2Limits(maxHeaderFields: 4u32))
        })
    }

    @TestCase
    func requestBodyProvesEofBeforeOneTerminalTrailerBlock(): Unit {
        let trailer = HttpTrailer(headers: HttpHeaders.builder().add("Digest", "done").build())
        let plan = mapHttp2ClientRequest(
            HttpRequest(HttpMethod("POST"), HttpUrl.parse("https://example.com/"), body: RequestBody.string("abc")),
            trailer: trailer
        )
        let body = plan.openBody()
        expectMappingError(Http2MessageErrorCode.InvalidMessageSequence, { => let _ = body.finishTrailers() })
        let buffer = Array<Byte>(2, repeat: 0)
        @Expect(body.read(buffer), 2)
        @Expect(body.read(buffer), 1)
        @Expect(body.read(buffer), 0)
        @Expect(body.consumedBytes, 3)
        let trailers = body.finishTrailers()
        expectMappingField(trailers, 0, "digest", "done")
        expectMappingError(Http2MessageErrorCode.InvalidMessageSequence, { => let _ = body.finishTrailers() })
        body.close()
        @Expect(body.isClosed())

        let two = HttpTrailer(headers: HttpHeaders.builder().add("X-One", "1").add("X-Two", "2").build())
        expectMappingError(Http2MessageErrorCode.InvalidHeader, { =>
            let _ = encodeHttp2TrailerFields(two, limits: Http2Limits(maxHeaderFields: 1u32))
        })
    }

    @TestCase
    func requestBodyRejectsPrematureEofAndConfiguredOverflow(): Unit {
        let short = RequestBody.replayableFactory(Some(3), { => MappingBodyStream([1u8, 2u8], Some(3)) })
        let shortBody = mapHttp2ClientRequest(
            HttpRequest(HttpMethod("POST"), HttpUrl.parse("https://example.com/"), body: short)
        ).openBody()
        let buffer = Array<Byte>(4, repeat: 0)
        @Expect(shortBody.read(buffer), 2)
        expectMappingError(Http2MessageErrorCode.BodyLengthMismatch, { => let _ = shortBody.read(buffer) })
        @Expect(shortBody.isClosed())

        let unknown = RequestBody.replayableFactory(None<Int64>, { => MappingBodyStream([1u8, 2u8, 3u8], None<Int64>) })
        let bounded = mapHttp2ClientRequest(
            HttpRequest(HttpMethod("POST"), HttpUrl.parse("https://example.com/"), body: unknown),
            limits: HttpLimits(maxBodyBytes: 2)
        ).openBody()
        expectMappingError(Http2MessageErrorCode.BodyLengthMismatch, { => let _ = bounded.read(buffer) })
    }

    @TestCase
    func responseMapsInformationalFinalDataAndTrailersInOrder(): Unit {
        let sequence = Http2ClientResponseSequence(Http2StreamId(1u32), HttpMethod("GET"))
        let informational = sequence.acceptHeaders([
            HpackHeaderField(":status", "103"), HpackHeaderField("link", "</style.css>")
        ], false)
        @Expect(isInformationalMapping(informational.kind))
        @Expect(informational.head.getOrThrow().status, 103)

        let final = sequence.acceptHeaders([
            HpackHeaderField(":status", "200"),
            HpackHeaderField("content-length", "3"),
            HpackHeaderField("x-result", "ok")
        ], false)
        @Expect(isFinalMapping(final.kind))
        let head = final.head.getOrThrow()
        @Expect(head.status, 200)
        @Expect(head.headers.getFirst("x-result"), Some("ok"))
        @Expect(head.expectedContentLength, Some(3))
        let response = head.toResponse(ResponseBody.empty())
        @Expect(response.version, HttpVersion.Http2)
        @Expect(response.reason, "")

        sequence.acceptData(1, false)
        sequence.acceptData(2, false)
        let trailer = sequence.acceptHeaders([HpackHeaderField("digest", "done")], true)
        @Expect(isTrailerMapping(trailer.kind))
        @Expect(trailer.trailer.getOrThrow().headers.getFirst("digest"), Some("done"))
        @Expect(sequence.bodyBytes, 3)
        @Expect(sequence.isTerminal)
    }

    @TestCase
    func responseRejectsPseudoOrderCaseAndConnectionFieldsAsStreamErrors(): Unit {
        expectResponseProtocol({ =>
            let _ = responseSequence().acceptHeaders([
                HpackHeaderField("x-first", "1"), HpackHeaderField(":status", "200")
            ], true)
        })
        expectResponseProtocol({ =>
            let _ = responseSequence().acceptHeaders([
                HpackHeaderField(":status", "200"), HpackHeaderField(":status", "204")
            ], true)
        })
        expectResponseProtocol({ =>
            let _ = responseSequence().acceptHeaders([
                HpackHeaderField(":status", "200"), HpackHeaderField("X-Bad", "1")
            ], true)
        })
        expectResponseProtocol({ =>
            let _ = responseSequence().acceptHeaders([
                HpackHeaderField(":status", "200"), HpackHeaderField("connection", "close")
            ], true)
        })
    }

    @TestCase
    func responseRejectsInvalidStatusAndTooManyInformationalHeads(): Unit {
        for (status in ["99", "600", "2x0", "101"]) {
            expectResponseProtocol({ =>
                let _ = responseSequence().acceptHeaders([HpackHeaderField(":status", status)], false)
            })
        }
        let sequence = responseSequence()
        for (_ in 0..16) {
            let _ = sequence.acceptHeaders([HpackHeaderField(":status", "103")], false)
        }
        expectResponseProtocol({ =>
            let _ = sequence.acceptHeaders([HpackHeaderField(":status", "103")], false)
        })
    }

    @TestCase
    func responseContentLengthMustMatchExactlyAtEndStream(): Unit {
        let early = responseSequence()
        let _ = early.acceptHeaders([
            HpackHeaderField(":status", "200"), HpackHeaderField("content-length", "2, 2")
        ], false)
        early.acceptData(1, false)
        expectResponseProtocol({ => early.acceptData(0, true) })

        let excess = responseSequence()
        let _ = excess.acceptHeaders([
            HpackHeaderField(":status", "200"), HpackHeaderField("content-length", "1")
        ], false)
        expectResponseProtocol({ => excess.acceptData(2, false) })

        expectResponseProtocol({ =>
            let _ = responseSequence().acceptHeaders([
                HpackHeaderField(":status", "200"), HpackHeaderField("content-length", "1")
            ], true)
        })
        expectResponseProtocol({ =>
            let limited = Http2ClientResponseSequence(
                Http2StreamId(1u32), HttpMethod("GET"), limits: HttpLimits(maxBodyBytes: 1)
            )
            let _ = limited.acceptHeaders([
                HpackHeaderField(":status", "200"), HpackHeaderField("content-length", "2")
            ], false)
        })
    }

    @TestCase
    func streamingResponseMayExceedTheConfiguredRequestBodyBound(): Unit {
        let sequence = Http2ClientResponseSequence(
            Http2StreamId(1u32), HttpMethod("GET"), limits: HttpLimits(maxBodyBytes: 2)
        )
        let _ = sequence.acceptHeaders([HpackHeaderField(":status", "200")], false)
        sequence.acceptData(2, false)
        sequence.acceptData(2, true)
    }

    @TestCase
    func bodylessAndConnectResponseRulesAreExplicit(): Unit {
        let head = Http2ClientResponseSequence(Http2StreamId(1u32), HttpMethod("HEAD"))
        let event = head.acceptHeaders([
            HpackHeaderField(":status", "200"), HpackHeaderField("content-length", "9")
        ], true)
        @Expect(event.head.getOrThrow().expectedContentLength, Some(9))
        expectResponseProtocol({ =>
            let _ = Http2ClientResponseSequence(Http2StreamId(1u32), HttpMethod("GET"))
                .acceptHeaders([HpackHeaderField(":status", "204")], false)
        })
        let reset = Http2ClientResponseSequence(Http2StreamId(1u32), HttpMethod("GET"))
        let _ = reset.acceptHeaders([
            HpackHeaderField(":status", "205"), HpackHeaderField("content-length", "0")
        ], true)
        @Expect(reset.isTerminal)
        expectResponseProtocol({ =>
            let _ = Http2ClientResponseSequence(Http2StreamId(1u32), HttpMethod("GET"))
                .acceptHeaders([
                    HpackHeaderField(":status", "205"), HpackHeaderField("content-length", "1")
                ], true)
        })
        expectResponseProtocol({ =>
            let _ = Http2ClientResponseSequence(Http2StreamId(1u32), HttpMethod("CONNECT"))
                .acceptHeaders([
                    HpackHeaderField(":status", "200"), HpackHeaderField("content-length", "0")
                ], false)
        })
    }

    @TestCase
    func responseTrailersRequireFinalEndStreamAndRegularAllowedFields(): Unit {
        let noEnd = responseSequence()
        let _ = noEnd.acceptHeaders([HpackHeaderField(":status", "200")], false)
        expectResponseProtocol({ =>
            let _ = noEnd.acceptHeaders([HpackHeaderField("digest", "done")], false)
        })

        let pseudo = responseSequence()
        let _ = pseudo.acceptHeaders([HpackHeaderField(":status", "200")], false)
        expectResponseProtocol({ =>
            let _ = pseudo.acceptHeaders([HpackHeaderField(":status", "200")], true)
        })

        let forbidden = responseSequence()
        let _ = forbidden.acceptHeaders([HpackHeaderField(":status", "200")], false)
        expectResponseProtocol({ =>
            let _ = forbidden.acceptHeaders([HpackHeaderField("content-length", "0")], true)
        })

        expectResponseProtocol({ =>
            let bounded = Http2ClientResponseSequence(
                Http2StreamId(1u32), HttpMethod("GET"),
                http2Limits: Http2Limits(maxHeaderFields: 1u32)
            )
            let _ = bounded.acceptHeaders([
                HpackHeaderField(":status", "200"), HpackHeaderField("x-extra", "1")
            ], true)
        })
        expectResponseProtocol({ =>
            let _ = responseSequence().acceptHeaders([
                HpackHeaderField(":status", "200"), HpackHeaderField("trailer", "content-length")
            ], true)
        })
    }
}

private class MappingBodyStream <: HttpBodyStream {
    private let bytes: Array<Byte>
    private let declared: ?Int64
    private var offset: Int64 = 0
    private var closed = false

    init(bytes: Array<Byte>, declared: ?Int64) { this.bytes = bytes.clone(); this.declared = declared }
    public prop contentLength: ?Int64 { get() { declared } }
    public func read(destination: Array<Byte>): Int64 {
        if (closed) { throw IllegalStateException("mapping body closed") }
        if (destination.isEmpty() || offset == bytes.size) { return 0 }
        let count = min(destination.size, bytes.size - offset)
        for (index in 0..count) { destination[index] = bytes[offset + index] }
        offset += count
        count
    }
    public func close(): Unit { closed = true }
    public func isClosed(): Bool { closed }
}

private func requestWithHeader(name: String, value: String): HttpRequest {
    HttpRequest(
        HttpMethod("GET"), HttpUrl.parse("https://example.com/"),
        headers: HttpHeaders.builder().add(name, value).build()
    )
}

private func responseSequence(): Http2ClientResponseSequence {
    Http2ClientResponseSequence(Http2StreamId(1u32), HttpMethod("GET"))
}

private func expectMappingField(
    fields: Array<HpackFieldEncoding>, index: Int64, name: String, value: String
): Unit {
    @Expect(fields[index].field.name, name)
    @Expect(fields[index].field.value, value)
}

private func expectMappingError(code: Http2MessageErrorCode, action: () -> Unit): Unit {
    var matched = false
    try { action() } catch (error: Http2MessageException) { matched = sameMappingCode(error.code, code) }
    @Expect(matched)
}

private func expectResponseProtocol(action: () -> Unit): Unit {
    var matched = false
    try { action() } catch (error: Http2ProtocolException) {
        matched = http2ErrorCodeToWire(error.code) == 1u32 && isMappingStreamScope(error.scope)
    }
    @Expect(matched)
}

private func sameMappingCode(left: Http2MessageErrorCode, right: Http2MessageErrorCode): Bool {
    match ((left, right)) {
        case (Http2MessageErrorCode.InvalidHeader, Http2MessageErrorCode.InvalidHeader) => true
        case (Http2MessageErrorCode.InvalidPseudoHeader, Http2MessageErrorCode.InvalidPseudoHeader) => true
        case (Http2MessageErrorCode.ForbiddenConnectionHeader, Http2MessageErrorCode.ForbiddenConnectionHeader) => true
        case (Http2MessageErrorCode.InvalidContentLength, Http2MessageErrorCode.InvalidContentLength) => true
        case (Http2MessageErrorCode.BodyLengthMismatch, Http2MessageErrorCode.BodyLengthMismatch) => true
        case (Http2MessageErrorCode.InvalidMessageSequence, Http2MessageErrorCode.InvalidMessageSequence) => true
        case _ => false
    }
}

private func isMappingStreamScope(scope: Http2ErrorScope): Bool {
    match (scope) { case Http2ErrorScope.Stream(_) => true; case _ => false }
}

private func isNeverIndexedMapping(mode: HpackIndexingMode): Bool {
    match (mode) { case HpackIndexingMode.NeverIndexed => true; case _ => false }
}

private func isInformationalMapping(kind: Http2ClientHeaderEventKind): Bool {
    match (kind) { case Http2ClientHeaderEventKind.Informational => true; case _ => false }
}

private func isFinalMapping(kind: Http2ClientHeaderEventKind): Bool {
    match (kind) { case Http2ClientHeaderEventKind.Final => true; case _ => false }
}

private func isTrailerMapping(kind: Http2ClientHeaderEventKind): Bool {
    match (kind) { case Http2ClientHeaderEventKind.Trailer => true; case _ => false }
}
